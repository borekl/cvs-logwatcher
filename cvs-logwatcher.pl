#!/usr/bin/perl

#=============================================================================
# CVS LOG WATCHER
# """""""""""""""
# Script to pull configuration log out of a network device after detecting
# change by observing the device's logfile. The details of operation are
# configured in cfg/config.json file.
#
# See README.md for more details.
#=============================================================================



#=============================================================================
#=== MODULES AND PRAGMAS                                                   ===
#=============================================================================

use strict;
use warnings;
use experimental 'signatures';
use IO::Async::Loop;
use IO::Async::FileStream;
use IO::Async::Signal;
use IO::Async::Timer::Periodic;
use Feature::Compat::Try;
use Path::Tiny;
use FindBin qw($Bin);
use Log::Log4perl::Level;
use lib "$Bin/lib";
use CVSLogwatcher::Config;
use CVSLogwatcher::Cmdline;
use CVSLogwatcher::Misc;

#-----------------------------------------------------------------------------
# This function encapsulates all of the processing of a single host. It
# downloads a config from a host, processes it and checks it into
# a repository. Arguments: target, host, msg, who, cmd.
sub process_host (%arg)
{
  # shortcut variables
  my $cfg = CVSLogwatcher::Config->instance;
  my $logger = $cfg->logger;
  my $host = $arg{host};
  my $target = $arg{target};
  my $cmd = $arg{cmd};

  # these two are either parsed from the logfile or supplied by the user when
  # manually triggering an action
  my $who = $arg{who} // $cmd->user // '';
  my $msg = $arg{msg} // $cmd->msg // '';

  # get base hostname (without domain name) and set up % tokens
  my $host_nodomain = host_strip_domain($arg{host});
  my $repl = $cfg->repl->add_value(
    '%H' => $host_nodomain,
    '%h' => $arg{host}
  );

  # get logging tag
  my $tag = "cvs/$host_nodomain";

  # log some basic information
  $logger->info("[$tag] Source host: $host (from syslog)");
  $logger->info("[$tag] Message:     ", $msg);
  $logger->info("[$tag] User:        ", $who) if $who;

  # skip if ignored user
  if($who && $cfg->is_ignored_user($who)) {
    $logger->info(qq{[$tag] Ignored user, skipping processing});
    return;
  }

  # skip if ignored host
  if($cfg->is_ignored_host($host_nodomain)) {
    $logger->info(qq{[$tag] Ignored host, skipping processing});
    return;
  }

  # get admin group
  my $group = $cfg->admin_group($host_nodomain) // $target->defgroup;
  if($group) {
    $logger->info(qq{[$tag] Admin group: $group});
  } else {
    $logger->error(qq{[$tag] No admin group for $host_nodomain, skipping});
    return;
  }

  # ensure reachability
  if($cfg->ping && system($repl->replace($cfg->ping)) >> 8) {
    $logger->error(qq{[$tag] Host $host_nodomain unreachable, skipping});
    return;
  }

  try {

    # run expect chat sequence, either the one specified on the command line
    # or the default one defined with 'deftask' key
    my (@files) = $target->expect->run_task($host, $cmd->task);

    # if no files received, finish
    die 'No files received, nothing to do' unless @files;

    # iterate over files received
    foreach my $file (@files) {

      # check for file's existence, abort if it does not exist
      $logger->info(sprintf(
        '[%s] File %s received, %d bytes',
        $tag, $file->file->stringify, -s $file->file
      ));

      # load the file into memory and remove it from the disk
      $file->remove;

      # convert line endings to local representation
      if($cmd->mangle && $target->has_option('normeol')) {
        $logger->debug(sprintf(
          '[%s] %d bytes stripped (normeol)', $tag, $file->normalize_eol
        ));
      }

      # filter out junk at the start and the end ("validrange" option)
      if($cmd->mangle && defined (my $diff = $file->validrange)) {
        $logger->debug(sprintf(
          '[%s] %d bytes stripped (validrange)', $tag, $diff
        ))
      }

      # filter out lines anywhere in the configuration ("filter" option)
      if($cmd->mangle && defined (my $diff = $file->filter)) {
        $logger->debug(sprintf(
          '[%s] %d bytes stripped (filter)', $tag, $diff
        ))
      }

      # validate the configuration
      if(my @failed = $file->validate) {
        $logger->warn("[$tag] Validation required but failed, aborting check in");
        $logger->debug(
          "[$tag] Failed validation expressions: ",
          join(', ', map { "'$_'" } @failed)
        );
        next;
      }

      # extract hostname from the configuration and set the extracted hostname
      # as the new filename
      if(my $confname = $file->extract_hostname) {
        $host_nodomain = $confname;
        $tag = "cvs/$confname";
        $logger->info("[$tag] Changing file name");
        $file->set_filename($confname);
      }

      # filename transform, user configurable filename transformation (currently
      # only uppercasing or lowercasing)
      $file->set_filename($target->mangle_hostname($file->file->basename));

      # compare to the last revision
      my $repo = CVSLogwatcher::File->new(
        file => $cfg->repodir->child($group, $file->file->basename . ',v'),
        target => $target
      );
      if(!$file->is_changed($repo)) {
        if($cmd->force) {
          $logger->info("[$tag] No change to current revision, but --force in effect");
        } else {
          $logger->info("[$tag] No change to current revision, skipping check-in");
          next;
        }
      }

      # create a new revision
      if(!defined $cmd->nocheckin) {
        $file->rcs_check_in(
          repo => $repo->file->parent,
          host => $host_nodomain,
          msg => $msg,
          who => $who
        );
        $logger->info("[$tag] CVS check-in completed successfully");
      }

      # command-line option --nocheckin in effect, but no directory or file
      # specified
      elsif($cmd->nocheckin eq '') {
        $logger->info("[$tag] CVS check-in inhibited, file not saved");
        next;
      }

      # command-line option --nocheckin in effect and directory/file specified
      else {
        my $dst = path $cmd->nocheckin;
        $dst = $cfg->tempdir->child($dst) if $dst->is_relative;
        $dst = $dst->child($host_nodomain) if $dst->is_dir;
        $file->file($dst);
        $file->save;
        $logger->info("[$tag] CVS check-in inhibited, file goes to ", $dst);
      }

    }
  } catch($err) {
    $logger->error("[$tag] Processing failed, ", $err);
  }
}

#=============================================================================
#===================  _  =====================================================
#===  _ __ ___   __ _(_)_ __  ================================================
#=== | '_ ` _ \ / _` | | '_ \  ===============================================
#=== | | | | | | (_| | | | | | ===============================================
#=== |_| |_| |_|\__,_|_|_| |_| ===============================================
#===                           ===============================================
#=============================================================================
#=============================================================================


# get command-line options
my $cmd = CVSLogwatcher::Cmdline->new;

# read configuration
my $cfg = CVSLogwatcher::Config->instance(
  basedir => path("$Bin"),
  config_file => "$Bin/cfg/config.json"
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

# verify command-line parameters
if($cmd->trigger) {
  if(!exists $cfg->logfiles->{$cmd->trigger}) {
    $logger->fatal(
      '[cvs] Option --trigger refers to non-existent logfile id, aborting'
    );
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

# manual run can be executed from the command line by using the --trigger=LOGID
# option. This might be used for creating the initial commit or for devices that
# cannot be triggered using logfiles. When using this mode --host=HOST must be
# used to tell which device(s) to check; --user and --msg should be used to
# specify commit author and message.

if($cmd->trigger && !$cmd->initonly) {

  # give some basic info
  $logger->info(sprintf('[cvs] Explicit target %s triggered', $cmd->trigger));
  $logger->info(sprintf('[cvs] Explicit host is %s', $cmd->host));
  $logger->info(sprintf('[cvs] Explicit user is %s', $cmd->user)) if $cmd->user;
  $logger->info(sprintf('[cvs] Explicit message is "%s"', $cmd->msg)) if $cmd->msg;

  # get list of hosts to process
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
    process_host(
      target => $target,
      host => $host,
      msg => $cmd->msg,
      who => $cmd->user,
      cmd => $cmd
    );
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

# iterate configured files
$cfg->iterate_logfiles(sub ($log) {
  my $logid = $log->id;

  # check if we are suppressing this logfile
  if(defined $cmd->log && $cmd->log ne $logid) {
    $logger->info(sprintf('[cvs] Suppressing %s (%s)', $log->file, $logid));
    return;
  }

  # open logfile for reading
  open my $logh,  '<', $log->file or die "Cannot open logfile '$logid' ($!)";

  # create new FileStream instance, attach handler code
  my $fs = IO::Async::FileStream->new(

    read_handle => $logh,
    filename => $log->file,

    on_initial => sub {
      my ($self) = @_;
      $self->seek_to_last( "\n" );
    },

    on_read => sub {
      my ($self, $buffref) = @_;
      while( $$buffref =~ s/^(.*\n)// ) {
        my $l = $1;
        # if --watchonly is active, display the line
        $logger->info("[cvs/$logid] $l") if $cmd->watchonly;
        # match line
        my ($host, $user, $msg) = $log->match($l);
        next unless $host;
        # find target
        my $target = $cfg->find_target($logid, $host);
        if(!$target) {
          $logger->warn(
            "[cvs] No target found for match from '$host' in source '$logid'"
          );
          next;
        }
        # finish if --watchonly
        next if $cmd->watchonly;
        # finish when --onlyuser specified and not matched
        if($cmd->onlyuser && $cmd->onlyuser ne $user) {
          $logger->info("[cvs/$logid] Skipping user $user\@$host (--onlyuser)");
          next;
        }
        # start processing
        process_host(
          target => $target,
          host => $host,
          msg => $msg,
          who => $user ? $user : 'unknown',
          cmd => $cmd,
        );
      }
      return 0;
    }

  );

  # register FileStream with the main event loop
  $ioloop->add($fs);
  $logger->info(
    sprintf('[cvs] Started observing %s (%s)', $log->file, $logid)
  );

});

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
