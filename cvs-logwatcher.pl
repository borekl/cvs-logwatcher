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
use File::Tail;
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
  my $tag = sprintf('cvs/%s', $host_nodomain);

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

    # run default expect chat sequence
    my ($file) = $target->expect->run_task($host);
    die sprintf("File %s does not exist", $file->file->stringify)
    unless $file->file->is_file;
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
      return;
    }

    # extract hostname from the configuration and set the extracted hostname
    # as the new filename
    if(my $confname = $file->extract_hostname) {
      $host_nodomain = $confname;
      $tag = "cvs/$confname";
      $logger->info("[$tag] Changing file name");
      $file->set_filename($confname);
    }

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
        return;
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
      return;
    }

    # command-line option --nocheckin in effect and directory/file specified
    else {
      my $dst = path $cmd->nocheckin;
      $dst = $cfg->tempdir->child($dst) if $dst->is_relative;
      if($dst->is_dir) {
        $dst = $dst->child($host_nodomain);
      }
      $file->file($dst);
      $file->save;
      $logger->info("[$tag] CVS check-in inhibited, file goes to ", $dst);
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

#-----------------------------------------------------------------------------
#--- manual check ------------------------------------------------------------
#-----------------------------------------------------------------------------

# manual run can be executed from the command line by using the
# --trigger=LOGID option. This might be used for creating the initial commit
# or for devices that cannot be triggered using logfiles. When using this mode
# --host=HOST must be used to tell which device(s) to check; --user and --msg
# should be used to specify commit author and message.

if($cmd->trigger) {

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
      $logger->warn("[cvs] No target found for match from '$host' in source '$cmd->trigger'");
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

#-----------------------------------------------------------------------------
#--- logfiles handling -------------------------------------------------------
#-----------------------------------------------------------------------------

# array of File::Tail filehandles
my @logfiles;

# loop over all configured logfiles
$cfg->iterate_logfiles(sub {
  my $log = shift;

  # check if we are suppressing this logfile
  if(defined $cmd->log && $cmd->log ne $log->id) {
    $logger->info(sprintf('[cvs] Suppressing %s (%s)', $log->file, $log->id));
    return;
  }

  # start watching the logfile
  my $h = File::Tail->new(
    name => $log->file,
    maxinterval => $cfg->tailparam('tailint')
  );
  $h->{'cvslogwatch.logid'} = $log->id;
  push(@logfiles, $h);

  $logger->info(
    sprintf('[cvs] Started observing %s (%s)', $log->file, $log->id)
  );
});

if(scalar(@logfiles) == 0) {
  $logger->fatal(qq{[cvs] No valid logfiles defined, aborting});
  die;
}

# if user specifies --initonly, do not enter the main loop, this is for testing
# purposes only
if($cmd->initonly) {
  $logger->info(qq{[cvs] Init completed, exiting});
  exit(0);
}

# main loop
$logger->debug('[cvs] Entering main loop');
while (1) {

  # wait for new data becoming available in any of the watched logs
  my ($nfound, $timeleft, @pending) = File::Tail::select(
    undef, undef, undef,
    $cfg->tailparam('tailmax'),
    @logfiles
  );

  # timeout reached without any data arriving
  if(!$nfound) {
    $logger->info('[cvs] Heartbeat');
    next;
  }

  # processing data
  foreach(@pending) {
    my $tid;

    # get next available line
    my $l = $_->read();
    chomp($l);

    # get filename of the file the line is from
    my $logid = $_->{'cvslogwatch.logid'};
    die 'Assertion failed, logid missing in File::Tail handle' if !$logid;
    my $log = $cfg->logfiles->{$logid};

    # if --watchonly is active, display the line
    $logger->info("[cvs/$logid] $l") if $cmd->watchonly;

    # match the line
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

    # start processing
    process_host(
      target => $target,
      host => $host,
      msg => $msg,
      who => $user ? $user : 'unknown',
      cmd => $cmd,
    );

  }
}
