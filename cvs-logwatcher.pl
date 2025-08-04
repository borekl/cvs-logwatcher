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
use IO::Async::Loop;
use IO::Async::Signal;
use IO::Async::Timer::Periodic;
use Feature::Compat::Try;
use List::Util qw(max);
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
  config_file => $cmd->config
);

# interactive code, ie. show something to user and exit
if($cmd->interactive) {

  #-----------------------------------------------------------------------------
  #--- match check -------------------------------------------------------------
  #-----------------------------------------------------------------------------

  # for debugging purposes it is possible to give the program a string to try
  # to match against configured regular expression and it will return the match
  # result; optionally, --log can be defined to constrain matching only to one
  # logfile configuration

  if($cmd->match) {
    $cfg->iterate_matches(sub ($l, $match_id) {
      return 0 if $cmd->log && $cmd->log ne $l->id;
      my $result = $l->match($cmd->match, $match_id);
      if(%$result && $result->{host}) {
        my $target = $cfg->find_target($match_id, $result->{host});
        my $tid = $target->id // 'n/a';
        printf("--- MATCH (logid=%s, matchid=%s) ---\n", $l->id, $match_id);
        printf("target:   %s\n", $tid);
        printf("%-8s: %s\n", $_, $result->{$_}) foreach (keys %$result);
        return 1;
      } else {
        printf("--- NO MATCH (logid=%s, matchid=%s) ---\n", $l->id, $match_id);
        return 0;
      }
    });
  }

  #-----------------------------------------------------------------------------
  #--- show configured logs ----------------------------------------------------
  #-----------------------------------------------------------------------------

  if($cmd->logs) {
    print "\n";
    if($cfg->logfiles->%*) {
      my @logfiles = sort keys $cfg->logfiles->%*;
      my $w1 = max (map { length } @logfiles, 5);
      my $w2 = max (map { length($cfg->logfiles->{$_}->file) } @logfiles);
      my $w3 = max (
        map {
          length(join(', ', map { $_->[0] } $cfg->logfiles->{$_}->matchre->@*))
        } @logfiles
      );
      printf("%-${w1}s  %-${w2}s  %-${w3}s\n", 'logid', 'filename', 'match ids');
      printf("%s  %s  %s\n", '=' x $w1, '=' x $w2, '=' x $w3);
      foreach my $logid (@logfiles) {
        printf(
          "%-${w1}s  %-${w2}s  %s\n",
          $logid, $cfg->logfiles->{$logid}->file,
          join(', ', map { $_->[0] } $cfg->logfiles->{$logid}->matchre->@*)
        );
      }
    } else {
      say 'No logs configured';
    }
    print "\n";
  }

  # don't go any further on interactive invocations
  exit(0);
}

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
foreach my $repo ($cfg->repos->@*) {
  my $type = ref($repo);
  $type =~ s/.*:://;
  $logger->debug(
    sprintf(qq{[cvs] Repository %s -> %s }, $type, $repo->base)
  );
}

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
#--- commit local file ---------------------------------------------------------
#-------------------------------------------------------------------------------

# manually commit a local file // this section is triggered by the --file=FILE
# command-line option; --host and --trigger must be specified, --msg and --user
# are optional; note, that all other file semantics apply, including automatic
# hostname discovery, file mangling and change detection

if($cmd->file) {

  # give some basic info
  $logger->info(sprintf('[cvs] Explicit target %s triggered', $cmd->trigger));
  $logger->info(sprintf('[cvs] Explicit host is %s', $cmd->host));
  $logger->info(sprintf('[cvs] Explicit user is %s', $cmd->user)) if $cmd->user;
  $logger->info(sprintf('[cvs] Explicit message is "%s"', $cmd->msg)) if $cmd->msg;
  $logger->info(sprintf('[cvs] Explicit file is %s', $cmd->file));

  # make sure there's associated target
  my $target = $cfg->find_target($cmd->trigger, lc($cmd->host));
  if(!$target) {
    $logger->warn(sprintf(
      "[cvs] No target found for match from '%s' in source '%s'",
      $cmd->host, $cmd->trigger
    ));
    exit(1);
  }

  # initialize required instances
  my $host = CVSLogwatcher::Host->new(
    name => $cmd->host, cmd => $cmd, who => $cmd->user, msg => $cmd->msg,
    target => $target, tag => ('cvs/' . $cmd->host), data => {},
  );
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
    try {
      my $fg = CVSLogwatcher::Host->new(
        target => $target,
        name => $host,
        msg => $cmd->msg,
        who => $cmd->user,
        cmd => $cmd,
        tag => sprintf('cvs/%s@%s', $target->id, $host),
        data => {},
      )->process;
      $fg->process;
    } catch ($err) {
      $logger->error("[cvs/$host] Failed to process host ($err)");
    }
  }

  # exit
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

  # check if the file is readable
  unless(-r $log->file) {
    $logger->warn(sprintf('[cvs] Skipping unreadable %s (%s)', $log->file, $logid));
    next;
  }

  # start watching
  $log->watch($ioloop, $cmd, sub ($host) {

    # get logging tag
    my $tag = $host->tag;

    try {

      #--- processing ----------------------------------------------------------

      # record stargin time
      my $processing_start = time;

      # log some basic information
      my ($h, $msg, $who) = ($host->name, $host->msg, $host->who);
      $logger->info("[$tag] Source host: $h");
      $logger->info("[$tag] Message:     ", $msg // '-');

      # skip if ignored user
      if($who && $cfg->is_ignored_user($who)) {
        $logger->info(sprintf(
          '[%s] User:        %s (ignored)', $tag, $who // '-'
        ));
        return;
      }

      # skip if ignored host
      if($cfg->is_ignored_host($host->host_nodomain)) {
        $logger->info(qq{[$tag] Ignored host, skipping processing});
        return;
      }

      # get admin group
      my $group = $host->admin_group;
      if($group) {
        $logger->info(sprintf(
          '[%s] User:        %s / %s', $tag, $who // '-', $group
        ));
      } else {
        $logger->info(sprintf(
          '[%s] User:        %s (no admin group)', $tag, $who // '-'
        ));
        return;
      }

      # retrieve files from remote devices or invoke preconfigure custom actions
      my $fg = $host->process;

      # process files
      $fg->process;

      # report duration of the entire processing
      $logger->info(sprintf(
        '[%s] Processing completed in %d seconds', $tag, time - $processing_start
      ));

    } catch ($err) {
      $logger->error("[$tag] Failed to process host ($err)");
    }

    #--- end of processing -----------------------------------------------------

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

# log rotation detection
$ioloop->add(IO::Async::Timer::Periodic->new(
  interval => 10,
  on_tick => sub {
    foreach my $log (values $cfg->logfiles->%*) {
      if($log->is_rotated) {
        $logger->info(sprintf(
          "[cvs] %s (%s) rotated", $log->file, $log->id
        ));
      }
    }
  }
)->start);

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
