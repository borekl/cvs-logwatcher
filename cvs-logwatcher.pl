#!/usr/bin/perl

#=============================================================================
# CVS LOG WATCHER
# """""""""""""""
# Script to pull configuration log out of a network device after detecting
# change by observing the device's logfile. The details of operation are
# configured in cfg/config.cfg file.
#
# See README.md for more details.
#=============================================================================

use strict;
use warnings;
use experimental 'signatures';
use IO::Async::Loop;
use IO::Async::Signal;
use IO::Async::Timer::Periodic;
use Feature::Compat::Try;
use Path::Tiny;
use FindBin qw($Bin);
use Log::Log4perl::Level;
use lib "$Bin/lib";
use CVSLogwatcher::Config;
use CVSLogwatcher::Cmdline;
use CVSLogwatcher::Host;

# get command-line options
my $cmd = CVSLogwatcher::Cmdline->new;

# read configuration
my $cfg = CVSLogwatcher::Config->instance(
  basedir => path("$Bin"),
  config_file => "$Bin/cfg/config.cfg"
);

# logging setup according to command-line
my $logger = $cfg->logger;
$logger->remove_appender($cmd->devel ? 'AFile' : 'AScrn');
$logger->level($cmd->debug ? $DEBUG : $INFO);

# title
$logger->info(qq{[cvs] --------------------------------});
$logger->info(qq{[cvs] NetIT CVS // Log Watcher started});
$logger->info(qq{[cvs] Mode is }, $cmd->devel ? 'development' : 'production');
$logger->debug(qq{[cvs] Debugging enabled}) if $cmd->debug;
$logger->debug(qq{[cvs] Log directory is }, $cfg->logprefix);
$logger->debug(qq{[cvs] Scratch directory is }, $cfg->tempdir);
$logger->debug(qq{[cvs] Repository directory is }, $cfg->repodir);

# verify that logfiles are configured
unless(keys $cfg->logfiles->%*) {
  $logger->fatal('[cvs] No valid logfiles configured, aborting');
  exit(1);
}

# verify command-line parameters
if($cmd->trigger) {
  if(!$cfg->exists_matchid($cmd->trigger)) {
    $logger->fatal(sprintf(
      q{[cvs] Option --trigger refers to non-existent match id '%s', aborting},
      $cmd->trigger
    ));
    exit(1);
  }
  if(!$cmd->host) {
    $logger->fatal(qq{[cvs] Option --trigger requires --host, aborting});
    exit(1);
  }
}

#-------------------------------------------------------------------------------
#--- manual check --------------------------------------------------------------
#-------------------------------------------------------------------------------

# manual run can be executed from the command line by using the
# --trigger=MATCHID option. This might be used for creating the initial commit
# or for devices that cannot be triggered using logfiles. When using this mode
# --host=HOST must be used to tell which device(s) to check; --user and --msg
# should be used to specify commit author and message.

if($cmd->trigger && !$cmd->initonly) {

  # give some basic info
  $logger->info(sprintf('[cvs] Explicit target %s triggered', $cmd->trigger));
  $logger->info(sprintf('[cvs] Explicit host is %s', $cmd->host));
  $logger->info(sprintf('[cvs] Explicit user is %s', $cmd->user)) if $cmd->user;
  $logger->info(sprintf('[cvs] Explicit message is "%s"', $cmd->msg)) if $cmd->msg;

  # get list of hosts to process; the following section implements expansion
  # of a host group specificed as '--host=@hostgroup' into list of hosts
  my @hosts;
  if($cmd->host =~ /^@(.*)$/) {
    my $group = $1;
    @hosts = @{$cfg->{'devgroups'}{$group}};
  } else {
    @hosts = ( $cmd->host );
  }

  # process each host
  for my $host (@hosts) {
    my $target = $cfg->find_target($cmd->trigger, lc($host));
    if(!$target) {
      $logger->warn(
        "[cvs] No target found for match from '$host' in source '$cmd->trigger'"
      );
      next;
    }
    CVSLogwatcher::Host->new(
      target => $target,
      name => $host,
      msg => $cmd->msg,
      who => $cmd->user,
      cmd => $cmd,
      data => {},
    )->process;
  }

  # exit
  $logger->info('[cvs] Finishing');
  exit(0);
}

#-------------------------------------------------------------------------------
#--- match check ---------------------------------------------------------------
#-------------------------------------------------------------------------------

# for debugging purposes it is possible to give the program a string to try
# to match against configured regular expression and it will return the match
# result; optionally, --log can be defined to constrain matching only to one
# logfile configuration

if($cmd->match) {
  $cfg->iterate_matches(sub ($l, $match_id) {
    return if $cmd->log && $cmd->log ne $l->id;
    my $result = $l->match($cmd->match, $match_id);
    if(%$result && $result->{host}) {
      my $target = $cfg->find_target($match_id, $result->{host});
      my $tid = $target->id // 'n/a';
      printf("--- MATCH (logid=%s, matchid=%s) ---\n", $l->id, $match_id);
      printf("target:   %s\n", $tid);
      printf("%-8s: %s\n", $_, $result->{$_}) foreach (keys %$result)
    } else {
      printf("--- NO MATCH (logid=%s, matchid=%s) ---\n", $l->id, $match_id);
    }
  });
  $logger->info('[cvs] Finishing');
  exit(0);
}

#-------------------------------------------------------------------------------
#--- logfiles handling ---------------------------------------------------------
#-------------------------------------------------------------------------------

# create event loop
my $ioloop = IO::Async::Loop->new;

# iterate configured files and their matches
foreach my $log (values $cfg->logfiles->%*) {
  my $logid = $log->id;

  # check if we are suppressing this logfile
  if(defined $cmd->log && $cmd->log ne $logid) {
    $logger->info(sprintf('[cvs] Suppressing %s (%s)', $log->file, $logid));
    next;
  }

  # start watching
  $log->watch($ioloop, $cmd, sub ($host) {
    $host->process;
  });
}

# if user specifies --initonly, do not enter the main loop, this is for testing
# purposes only
if($cmd->initonly) {
  $logger->info(qq{[cvs] Init completed, exiting});
  exit(0);
}

# signal handling
foreach my $sig (qw(INT TERM)) {
  $ioloop->add(IO::Async::Signal->new(
    name => $sig, on_receipt => sub {
      $logger->info("[cvs] SIG$sig received, terminating");
      $ioloop->stop;
    }
  ));
}

# heartbeat timer
if($cmd->heartbeat) {
  $ioloop->add(IO::Async::Timer::Periodic->new(
    interval => $cmd->heartbeat,
    on_tick => sub { $logger->info('[cvs] Heartbeat') }
  )->start);
}

# run event loop
$logger->debug('[cvs] Starting main loop');
$ioloop->run;
