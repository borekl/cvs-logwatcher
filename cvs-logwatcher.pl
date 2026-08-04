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

use v5.36;
use Time::HiRes qw(time);
use IO::Async::Loop;
use IO::Async::Signal;
use Feature::Compat::Try;
use Path::Tiny;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CVSLogwatcher::Config;
use CVSLogwatcher::Cmdline;
use CVSLogwatcher::Host;
use CVSLogwatcher::TestMatch;
use CVSLogwatcher::Logger;

# get logger
my $logger = CVSLogwatcher::Logger->instance;

# get command-line options
my $cmd = CVSLogwatcher::Cmdline->new;

# title
unless($cmd->interactive) {
  $logger->info('--------------------------------');
  $logger->info('NetIT CVS // Log Watcher started');
  $logger->level($cmd->debug ? 'debug' : 'info');
  $logger->debug('Debugging enabled') if $cmd->debug;
}

# read configuration
my $cfg = CVSLogwatcher::Config->instance(
  basedir => path("$Bin"),
  config_file => $cmd->config
);

# interactive code, ie. show something to user and exit
if($cmd->interactive) {

  # --match, --match-stdin // options for troubleshooting logfile entries
  # matching; the --match option allows pass string on the command-line (can be
  # use more than once), --match-stdin takes lines from standard input; each
  # line produces matching results; --log option can constrain matching to one
  # specific logfile
  my $tstm = CVSLogwatcher::TestMatch->new;
  my $line_count = 1;
  $cmd->match_lines(sub ($l) {
    printf("=== LINE %s ===\n", $line_count++);
    $tstm->test_match($l, $cmd->log);
  });

  # --logs // display configured logs along with match definitions
  if($cmd->logs) {
    $cfg->display_logs;
  }

  # don't go any further on interactive invocations
  exit(0);
}

# title
$logger->debug('Log directory is %s', $cfg->logprefix);
$logger->debug('Scratch directory is %s', $cfg->tempdir);
foreach my $repo ($cfg->repos->@*) {
  my $type = ref($repo);
  $type =~ s/.*:://;
  $logger->debug('Repository %s -> %s ', $type, $repo->base);
}

# verify that keyring is correct, we want to fail on startup if it is not
$cfg->keyring;

# verify that logfiles are configured
unless(keys $cfg->logfiles->%*) {
  $logger->fatal('No valid logfiles configured, aborting');
  exit(1);
}

# verify command-line parameters
if($cmd->trigger) {
  if(!$cfg->exists_matchid($cmd->trigger)) {
    $logger->fatal(
      qq{Option --trigger refers to non-existent match id '%s', aborting},
      $cmd->trigger
    );
    exit(1);
  }
  if(!$cmd->host) {
    $logger->fatal(qq{Option --trigger requires --host, aborting});
    exit(1);
  }
}

#-------------------------------------------------------------------------------
#--- commit local file ---------------------------------------------------------
#-------------------------------------------------------------------------------

# manually commit a local file // this section is triggered by the --file=FILE
# command-line option; --host and --trigger must be specified, --msg and --user
# are optional; note, that all other file semantics apply, including automatic
# hostname discovery, file mangling and change detection

if($cmd->file) {

  # make sure command-line specifies everything we need
  my @unspecified;
  push(@unspecified, '--trigger') unless $cmd->trigger;
  push(@unspecified, '--host') unless $cmd->host;
  die sprintf('%s not specified', join(' and ', @unspecified)) if @unspecified;

  # give some basic info
  $logger->info('Explicit target %s triggered', $cmd->trigger);
  $logger->info('Explicit host is %s', $cmd->host);
  $logger->info('Explicit user is %s', $cmd->user) if $cmd->user;
  $logger->info('Explicit message is "%s"', $cmd->msg) if $cmd->msg;
  $logger->info('Explicit file is %s', $cmd->file);

  # make sure there's associated target
  my $target = $cfg->find_target($cmd->trigger, lc($cmd->host));
  if(!$target) {
    $logger->warn(
      qq{No target found for match from '%s' in source '%s'},
      $cmd->host, $cmd->trigger
    );
    exit(1);
  }

  # initialize required instances
  my $host = CVSLogwatcher::Host->new(cmd => $cmd, target => $target);
  my $file = CVSLogwatcher::File->new(file => $cmd->file);
  my $fg = CVSLogwatcher::FileGroup->new(
    host => $host, files => [ $file ], target => $target, cmd => $cmd
  );
  $fg->process;

  exit(0);
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
  $logger->info('Explicit target %s triggered', $cmd->trigger);
  $logger->info('Explicit host is %s', $cmd->host);
  $logger->info('Explicit user is %s', $cmd->user) if $cmd->user;
  $logger->info('Explicit message is "%s"', $cmd->msg) if $cmd->msg;

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
        "No target found for match from '%s' in source '%s'",
        $host, $cmd->trigger
      );
      next;
    }
    try {
      my $processing_start = time;

      my $fg = CVSLogwatcher::Host->new(
        target => $target,
        cmd => $cmd,
        tag => sprintf('cvs/%s@%s', $target->id, $host),
      )->process;
      $fg->process;

      # report duration of the entire processing
      $logger->info(
        'Processing completed in %.1f seconds', time - $processing_start
      );
    } catch ($err) {
      my $logger_host = $logger->prefix("cvs/$host");
      $logger_host->error('Failed to process host (%s)', $err);
    }
  }

  # exit
  $logger->info('Finishing');
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
    $logger->info('Suppressing %s (%s)', $log->file, $logid);
    next;
  }

  # check if the file is readable
  unless(-r $log->file) {
    $logger->warn('Skipping unreadable %s (%s)', $log->file, $logid);
    next;
  }

  # start watching
  $log->watch($ioloop, $cmd, sub ($host) {

    my $logger2 = $logger->prefix('cvs/' . $host->tag);

    try {

      #--- processing ----------------------------------------------------------

      # record stargin time
      my $processing_start = time;

      # log some basic information
      my ($h, $msg, $who) = ($host->name, $host->msg, $host->who);
      $logger2->info('Source host: %s', $h);
      $logger2->info('Message:     %s', $msg // '-');

      # skip if ignored user
      if($who && $cfg->is_ignored_user($who)) {
        $logger2->info('User:        %s (ignored)', $who // '-');
        return;
      }

      # skip if ignored host
      if($cfg->is_ignored_host($host->host_nodomain)) {
        $logger2->info('Ignored host, skipping processing');
        return;
      }

      # get admin group
      my $group = $host->admin_group;
      if($group) {
        $logger2->info('User:        %s / %s', $who // '-', $group);
      } else {
        $logger2->info('User:        %s (no admin group)', $who // '-');
        return;
      }

      # retrieve files from remote devices or invoke preconfigure custom actions
      my $fg = $host->process;

      # process files
      $fg->process;

      # report duration of the entire processing
      $logger2->info(
        'Processing completed in %.1f seconds', time - $processing_start
      );

    } catch ($err) {
      $logger2->error('Failed to process host (%s)', $err);
    }

    #--- end of processing -----------------------------------------------------

  });
}

# if user specifies --initonly, do not enter the main loop, this is for testing
# purposes only
if($cmd->initonly) {
  $logger->info('Init completed, exiting');
  exit(0);
}

# signal handling
foreach my $sig (qw(INT TERM)) {
  $ioloop->add(IO::Async::Signal->new(
    name => $sig, on_receipt => sub {
      $logger->info("SIG$sig received, terminating");
      $ioloop->stop;
    }
  ));
}

# log rotation detection
$ioloop->add(IO::Async::Timer::Periodic->new(
  interval => 10,
  on_tick => sub {
    foreach my $log (values $cfg->logfiles->%*) {
      if($log->update_inode) {
        $logger->info('%s (%s) rotated', $log->file, $log->id);
        $log->reopen;
      }
    }
  }
)->start);

# run event loop
$logger->debug('Starting main loop');
$ioloop->run;
$logger->debug('Main loop shutdown');
