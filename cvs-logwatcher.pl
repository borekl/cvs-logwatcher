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
use Carp;
use Expect;
use JSON;
use File::Tail;
use Getopt::Long;
use Feature::Compat::Try;
use Path::Tiny;
use FindBin qw($Bin);
use Log::Log4perl::Level;
use lib "$Bin/lib";
use CVSLogwatcher::Config;
use CVSLogwatcher::Cmdline;
use CVSLogwatcher::Misc;

#=============================================================================
#=== GLOBAL VARIABLES                                                      ===
#=============================================================================

my ($cfg, $cfg2);

#=============================================================================
#=== FUNCTIONS                                                             ===
#=============================================================================

#=============================================================================
# Execute batch of expect-response pairs. If there's third value in the
# arrayref containing the exp-resp pair, it will be taken as a file to
# begin logging into.
#
# The expect chat definition has this form:
#
# {
#   spawn => "command to run",
#   sleep => N,
#   chat => [
#     [ "expect string", "response string", "logfile", "prompt" ],
#     ...
#   ]
# }
#
# All of the string values can use replacement tokens (using
# CVSLogwatcher::Repl::replace() function. The expect string can use capture
# groups, that are available to response strings as %+0, %+1, etc.
#
# The "logfile" element is optional; when present, the output is recorded
# into specified file.
#
# The "prompt" element is optional; when preset it sets the value of the %P
# replacement -- this is intended for setting up system prompt string.
#=============================================================================

sub run_expect_batch
{
  #--- arguments

  my (
    $expect_def,    # 1. expect conversation definitions from the config.json
    $host,          # 2. hostname
    $host_nodomain, # 3. hostname without domain
    $logpf,         # 4. logging message prefix
  ) = @_;

  # create local Repl instance
  my $repl = $cfg2->repl->clone;

  # get logger
  my $logger = $cfg2->logger;

  #--- variables

  my $spawn = $repl->replace($expect_def->{'spawn'});
  my $sleep = $expect_def->{'sleep'};
  my $chat = $expect_def->{'chat'};

  #--- spawn command

  $logger->debug("[$logpf] Spawning Expect instance ($spawn)");
  $logger->debug("[$logpf] Chat definition has " . @$chat . ' lines');
  my $exh = Expect->spawn($spawn) or do {
    $logger->fatal("[$logpf] Failed to spawn Expect instance ($spawn)");
    return;
  };
  $exh->log_stdout(0);
  $exh->restart_timeout_upon_receive(1);
  $exh->match_max(8192);

  try { #<--- try block begins here ------------------------------------------

    my $i = 1;
    for my $row (@$chat) {

      $logger->debug(
        sprintf('[%s] Expect chat line --- %d', $logpf, $i)
      );

      my $chat_send = $repl->replace($row->[1]);
      my $chat_send_disp;
      my $open_log = $repl->replace($row->[2]);

      #--- hide passwords, make CR visible
      $chat_send_disp = $chat_send;
      if($row->[0] =~ /password/i) {
        $chat_send_disp = '***';
      }
      if($chat_send eq "\r") {
        $chat_send_disp = '[CR]';
      }

      #--- open log
      if($open_log) {
        $exh->log_file($open_log, 'w') or die;
        $logger->info("[$logpf] Logfile opened: ", $open_log);
      }

      #--- perform the handshake
      $logger->debug(
        sprintf('[%s] Expect string(%d): %s', $logpf, $i, $repl->replace($row->[0]))
      );
      $exh->expect($cfg2->tailparam('expmax') // 300, '-re', $repl->replace($row->[0])) or die;
      my @g = $exh->matchlist();
      $logger->debug(
        sprintf('[%s] Expect receive(%d): %s', $logpf, $i, $exh->match())
      );
      if(@g) {
        $logger->debug(
          sprintf('[%s] Expect groups(%d): %s', $logpf, $i, join(',', @g))
        );
      }
      $repl->add_capture_groups(@g);
      if($row->[3]) {
        $repl->add_value('%P' => quotemeta($repl->replace($row->[3])))
      };
      sleep($sleep) if $sleep;
      $logger->debug(
        sprintf('[%s] Expect send(%d): %s', $logpf, $i, $repl->replace($chat_send_disp))
      );
      $exh->print($repl->replace($row->[1]));

      #--- next line
      $i++;
    }

  } #<--- try block ends here ------------------------------------------------

  catch ($e) {
    $logger->error(qq{[$logpf] Expect failed for host $host});
    $logger->debug("[$logpf] Failure reason is: ", $e);
  }

  sleep($sleep) if $sleep;
  $exh->soft_close();
}



#=============================================================================
# Compare a file with its last revision in CVS and return true if there is a
# difference.
#=============================================================================

sub compare_to_prev
{
  #--- arguments

  my (
    $target,   # 1. target
    $host,     # 2. host
    $file,     # 3. file to compare
    $repo,     # 4. repository file
  ) = @_;

  #--- other variables

  my ($re_src, $re_com);
  my $logger = cfg2->logger;
  my $logpf = '[cvs/' . $target->{'id'}  . ']';

  #--- read the new file

  open my $fh, $file or die "Could not open file '$file'";
  chomp( my @new_file = <$fh> );
  close $fh;

  #--- remove ignored lines

  if(exists $target->{'ignoreline'}) {
    $re_src = $target->{'ignoreline'};
    $re_com = qr/$re_src/;
    $logger->debug("$logpf Ignoreline regexp: ", $re_src);
    @new_file = grep { !/$re_com/ } @new_file;
  }

  #--- read the most recent CVS version

  my $exec = sprintf(
    '%s -q -p %s/%s,v',
    $cfg2->rcs('rcsco'),
    $repo,
    $host
  );
  $logger->debug("$logpf Cmd: $exec");
  open $fh, '-|', "$exec 2>/dev/null"
    or die "Could not get latest revision from '$exec'";
  chomp( my @old_file = <$fh> );
  close $fh;
  @old_file = grep { !/$re_com/ } @old_file if $re_com;

  #--- compare line counts

  $logger->debug(
    "$logpf ",
    sprintf(
      'Linecounts: new = %d, repo = %d', scalar(@new_file), scalar(@old_file)
    )
  );
  return 1 if @new_file != @old_file;

  #--- compare contents

  for(my $i = 0; $i < @new_file; $i++) {
    return 1 if $new_file[$i] ne $old_file[$i];
  }

  #--- return false

  return 0;

}


#=============================================================================
# Process a match
#=============================================================================

sub process_match
{
  #--- arguments

  my (
    $tid,               # 1. target id
    $host,              # 2. host
    $msg,               # 3. message
    $chgwho,            # 4. username
    $cmd,               # 5. CVSL::Cmdline instance
  ) = @_;

  #--- other variables
  my $host_nodomain;          # hostname without domain
  my $group;                  # administrative group
  my $file;                   # file holding retrieved configuration
  my $repl = $cfg2->repl;     # Repl instance
  my $logger = $cfg2->logger; # logger instance

  # get the target instance
  my $target = $cfg2->get_target($tid);
  if(!$target) {
    $logger->error("Target '$tid' not found, no action taken");
    return;
  }

  #--- log some information

  $logger->info(qq{[cvs/$tid] Source host: $host (from syslog)});
  $logger->info(qq{[cvs/$tid] Message:     }, $msg);
  $logger->info(qq{[cvs/$tid] User:        }, $chgwho) if $chgwho;

  #--- skip if ignored user

  # "ignoreusers" configuration object is a list of users that should
  # be ignored and no processing be done for them

  if($chgwho && $cfg2->is_ignored_user($chgwho)) {
    $logger->info(qq{[cvs/$tid] Ignored user, skipping processing});
    return;
  }

  #--- skip if ignored hosts

  # "ignorehosts" configuration object is a list of regexps that
  # if any one of them matches hostname as received from logfile,
  # causes the processing to abort; this allows to ignore certain
  # source hosts

  if($cfg2->is_ignored_host($host)) {
    $logger->info(qq{[cvs/$tid] Ignored host, skipping processing});
    return;
  }

  #--- get hostname without trailing domain name

  $host_nodomain = $host;
  $host_nodomain =~ s/\..*$//g;
  $repl->add_value(
    '%H' => $host_nodomain,
    '%h' => $host
  );

  #--- assign admin group

  $group = $cfg2->admin_group($host_nodomain) // $target->defgroup;
  if($group) {
    $logger->info(qq{[cvs/$tid] Admin group: $group});
  } else {
    $logger->error(qq{[cvs/$tid] No admin group for $host_nodomain, skipping});
    return;
  }

  #--- ensure reachability

  if($cfg2->ping && system($repl->replace($cfg2->ping)) >> 8) {
    $logger->error(qq{[cvs/$tid Host $host_nodomain unreachable, skipping});
    return;
  }

  #--------------------------------------------------------------------------
  #--- retrieve configuration from a device ---------------------------------
  #--------------------------------------------------------------------------

  {

  #--- default config file location, this can later be changed if we are
  #--- extracting hostname from the configuration

    $file = $cfg2->tempdir->child($host_nodomain);

  #--- run expect script ----------------------------------------------------

    if($target->config->{'expect'}) {
      run_expect_batch(
        $target->config->{'expect'},
        $host, $host_nodomain,
        "cvs/$tid"
      );
    }
  }

  #--------------------------------------------------------------------------

  try {

  #--------------------------------------------------------------------------
  #--- RCS check-in ---------------------------------------------------------
  #--------------------------------------------------------------------------

    my ($exec, $rv);
    my $repo = sprintf(
      '%s/%s', $cfg->{'rcs'}{'rcsrepo'}, $group
    );

  #--- check if we really have the input file

    if(! -f $file) {
      $logger->fatal(
        "[cvs/$tid] File $file does not exist, skipping further processing"
      );
      die;
    } else {
      $logger->info(
        sprintf('[cvs/%s] File %s received, %d bytes', $tid, $file, -s $file )
      );
    }

  #--- convert line endings to local style

    if($cmd->mangle && $target->has_option('normeol')) {
      my $done;
      if(open(FOUT, '>', "$file.eolconv.$$")) {
        if(open(FIN, '<', $file)) {
          while(my $l = <FIN>) {
            $l =~ s/\R//;
            print FOUT $l, "\n";
          }
          close(FIN);
          $done = 1;
        }
        close(FOUT);
        if($done) {
          $logger->debug(
            sprintf(
              '[cvs/%s] Config reduced from %d to %d bytes (normeol)',
              $tid, -s $file, -s "$file.eolconv.$$"
            )
          );
          rename("$file.eolconv.$$", $file);
        } else {
          remove("$file.eolconv.$$");
        }
      }
    }

  #--- filter out junk at the start and at the end ("validrange")

  # If "validrange" is specified for a target, then the first item in it
  # specifies regex for the first valid line of the config and the second
  # item specifies regex for the last valid line.  Either regex can be
  # undefined which means the config range starts on the first line/ends on
  # the last line.  This allows filtering junk that is saved with the config
  # (echo of the chat commands, disconnection message etc.)

    if($cmd->mangle && (my $vr = $target->validrange)) {
      if(open(FOUT, '>', "$file.validrange.$$")) {
        if(open(FIN, '<', "$file")) {
          while(my $l = <FIN>) {
            print FOUT $l if $vr->($l);
          }
          close(FIN);
          $logger->debug(
            sprintf(
              '[cvs/%s] Config reduced from %d to %d bytes (validrange)',
              $tid, -s $file, -s "$file.validrange.$$"
            )
          );
          rename("$file.validrange.$$", $file);
        }
        close(FOUT);
      }
    }

  #--- filter out selected lines anywhere in the configuration

  # This complements above "validrange" feature by filtering by set of regexes.
  # Any line matching any of the regexes in array "filter" is thrown away.

    if($cmd->mangle && $target->has_filter) {
      if(open(FOUT, '>', "$file.filter.$$")) {
        if(open(FIN, '<', "$file")) {
          while(my $l = <FIN>) {
            print FOUT $l if $target->filter_pass($l);
          }
          close(FIN);
          $logger->debug(
            sprintf(
              '[cvs/%s] Config reduced from %d to %d bytes (filter)',
              $tid, -s $file, -s "$file.filter.$$"
            )
          );
          rename("$file.filter.$$", $file);
        }
        close(FOUT);
      }
    }

  #--- "validate" option

  # This option is an array of regexes that each must be matched at least
  # once per config.  When this condition is not met, the configuration is
  # rejected as incomplete.  This is to protect against interrupted
  # transfers that would drop valid data from repository. --nocheckin
  # prevents validation.

    if(!defined $cmd->nocheckin && (my $v = $target->validate_checker)) {
      if(open(FIN, '<', $file)) {
        while(my $l = <FIN>) { last if !$v->($l) }
        if($v->()) {
          $logger->warn("[cvs/$tid] Validation required but failed, aborting check in");
          $logger->debug(
            "[cvs/$tid] Failed validation expressions: ",
            join(', ', map { "'$_'" } $v->())
          );
          die;
        }
        close(FIN);
      }
    }

  #--- extract hostname from the configuration

  # This makes it possible to use host's own notion of hostname avoiding
  # reliance on the name that appears in syslog

    if($target->config->{hostname}) {
      my $selfname = extract_hostname($file, $target->config->{hostname});
      if($selfname && $selfname ne $file->basename) {
        my $target = $file->sibling($selfname);
        $file->move($target);
        $logger->info(sprintf(
          "[cvs/$tid] Changing name from %s to %s",
          $file->basename, $selfname
        ));
        $file = $target;
        $host_nodomain = $file->basename;
      }
    }

  #--- --nocheckin option

  # This blocks actually checking the file into the repository, instead the
  # file is either left where it was received (when --nocheckin has no
  # pathname specification) or it is saved into different location and
  # filename (when --nocheckin specifies path/filename).

    if(defined $cmd->nocheckin) {
      if($cmd->nocheckin ne '') {
        my $dst_file = $cmd->nocheckin;

        # check whether --nocheckin value specifies existing directory, if
        # it does, move the current file with its "received" filename to the
        # directory; otherwise, move the current file into specified target
        # file

        if(-d $cmd->nocheckin) {
          my $ci_dir = $cmd->nocheckin;
          $ci_dir =~ s/\/+$//;
          $dst_file = $ci_dir . '/' . $host_nodomain;
        }
        $logger->info("[cvs/$tid] No check in requested, moving config to $dst_file instead");
        rename($file, $dst_file);
      } else {
        $logger->info("[cvs/$tid] No check in requested, leaving the file in $file");
      }
      die "NOREMOVE\n";
    }

  #--- compare current version with the most recent CVS version

  # This is done to avoid storing configs that are not significantly
  # changed. Normally, even if user doesn't make change to configrations
  # on some platforms, the config files still change because they contain
  # things like date of config generation etc. Following code goes over
  # the files and compares them line by line, but disregard changes
  # in comment lines (comment lines are not editable by user anyway).
  # What is considered a comment or other non-significant part of the
  # configuration is decided by matching regex from "ignoreline"
  # configuration item.

    if(!compare_to_prev($target->config, $host_nodomain, $file, $repo)) {
      if($cmd->force) {
        $logger->info("[cvs/$tid] No change to current revision, but --force in effect");
      } else {
        $logger->info("[cvs/$tid] No change to current revision, skipping check-in");
        die 'OK';
      }
    }

  #--- create new revision

    # is this really needed? I have no idea.
    if(-f "$repo/$host_nodomain,v") {
      $exec = sprintf(
        '%s -q -U %s/%s,v',
        $cfg2->rcs('rcsctl'),                        # rcs binary
        $repo, $host_nodomain                        # config in repo
      );
      $logger->debug("[cvs/$tid] Cmd: $exec");
      $rv = system($exec);
      if($rv) {
        $logger->error("[cvs/$tid] Cmd failed with: ", $rv);
        die;
      }
    }

    $exec = sprintf(
      '%s -q -w%s "-m%s" -t-%s %s %s/%s,v',
      $cfg2->rcs('rcsci'),                         # rcs ci binary
      $chgwho,                                     # author
      $msg,                                        # commit message
      $host,                                       # file description
      $file,                                       # tftp directory
      $repo, $host_nodomain                        # config in repo
    );
    $logger->debug("[cvs/$tid] Cmd: $exec");
    $rv = system($exec);
    if($rv) {
      $logger->error("[cvs/$tid] Cmd failed with: ", $rv);
      die;
    }

    $logger->info(qq{[cvs/$tid] CVS check-in completed successfully});

  #--- end of try block ------------------------------------------------------

  } catch ($e) {
    # log the error (special 'NOREMOVE' and 'OK' values are not logged)
    $logger->error(qq{[cvs/$tid] Check-in failed ($e)})
    unless $e eq 'NOREMOVE' or $e =~ /^OK\s/;
    # remove the file, unless specifically instructed not to
    if(-f "$file" && $e ne "NOREMOVE\n" ) {
      $logger->debug(qq{[cvs/$tid] Removing file $file});
      $file->remove;
    }
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

#--- read configuration ------------------------------------------------------

$cfg2 = CVSLogwatcher::Config->new(
  basedir => path("$Bin"),
  config_file => "$Bin/cfg/config.json"
);
$cfg = $cfg2->config;

# logging setup according to command-line
my $logger = $cfg2->logger;
$logger->remove_appender($cmd->devel ? 'AFile' : 'AScrn');
$logger->level($cmd->debug ? $DEBUG : $INFO);

# initialize token for tempdir
$cfg2->repl->add_value('%D' => $cfg2->tempdir->stringify);

#--- title -------------------------------------------------------------------

$logger->info(qq{[cvs] --------------------------------});
$logger->info(qq{[cvs] NetIT CVS // Log Watcher started});
$logger->info(qq{[cvs] Mode is }, $cmd->devel ? 'development' : 'production');
$logger->debug(qq{[cvs] Debugging enabled}) if $cmd->debug;
$logger->debug(qq{[cvs] Log directory is }, $cfg2->logprefix);
$logger->debug(qq{[cvs] Scratch directory is }, $cfg2->tempdir);
$logger->debug(qq{[cvs] Repository directory is }, $cfg2->repodir);

#--- verify command-line parameters ------------------------------------------

if($cmd->trigger) {
  if(!exists $cfg->{'logfiles'}{$cmd->trigger}) {
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


if($cmd->trigger) {
  $logger->info(sprintf('[cvs] Explicit target %s triggered', $cmd->trigger));
  $logger->info(sprintf('[cvs] Explicit host is %s', $cmd->host));
  $logger->info(sprintf('[cvs] Explicit user is %s', $cmd->user)) if $cmd->user;
  $logger->info(sprintf('[cvs] Explicit message is "%s"', $cmd->msg)) if $cmd->msg;
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
    my $tid = $cfg2->find_target($cmd->trigger, lc($host));
    if(!$tid) {
      $logger->warn("[cvs] No target found for match from '$host' in source '$cmd->trigger'");
      next;
    }
    process_match(
      $tid,
      $host,
      $cmd->msg // 'Manual check-in',
      $cmd->user // 'cvs',
      $cmd,
    );
  }

  # exit
  $logger->info('[cvs] Finishing');
  exit(0);
}

#-----------------------------------------------------------------------------
#--- logfiles handling -------------------------------------------------------
#-----------------------------------------------------------------------------

#--- initializing the logfiles -----------------------------------------------

# array of File::Tail filehandles
my @logfiles;

# loop over all configured logfiles
$cfg2->iterate_logfiles(sub {
  my $log = shift;

  # check if we are suppressing this logfile
  if(defined $cmd->log && $cmd->log ne $log->id) {
    $logger->info(sprintf('[cvs] Suppressing %s (%s)', $log->file, $log->id));
    return;
  }

  # start watching the logfile
  my $h = File::Tail->new(
    name => $log->file,
    maxinterval => $cfg2->tailparam('tailint')
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

#--- if user specifies --initonly, do not enter the main loop
#--- this is for testing purposes

if($cmd->initonly) {
  $logger->info(qq{[cvs] Init completed, exiting});
  exit(0);
}

#--- main loop

$logger->debug('[cvs] Entering main loop');
while (1) {

#--- wait for new data becoming available in any of the watched logs

  my ($nfound, $timeleft, @pending) = File::Tail::select(
    undef, undef, undef,
    $cfg2->tailparam('tailmax'),
    @logfiles
  );

#--- timeout reached without any data arriving

  if(!$nfound) {
    $logger->info('[cvs] Heartbeat');
    next;
  }

#--- processing data

  foreach(@pending) {
    my $tid;

    #--- get next available line
    my $l = $_->read();
    chomp($l);

    #--- get filename of the file the line is from
    my $logid = $_->{'cvslogwatch.logid'};
    die 'Assertion failed, logid missing in File::Tail handle' if !$logid;
    my $log = $cfg2->logfiles->{$logid};

    #--- if --watchonly is active, display the line
    $logger->info("[cvs/$logid] $l") if $cmd->watchonly;

    #--- match the line
    my ($host, $user, $msg) = $log->match($l);
    next unless $host;

    #--- find target
    $tid = $cfg2->find_target($logid, $host);

    if(!$tid) {
      $logger->warn(
        "[cvs] No target found for match from '$host' in source '$logid'"
      );
      next;
    }

    #--- finish if --watchonly

    next if $cmd->watchonly;

    #--- start processing
    process_match(
      $tid,
      $host,
      $msg,
      $user ? $user : 'unknown',
      $cmd,
    );

  }
}
