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
use Log::Log4perl qw(get_logger);
use Log::Log4perl::Level;
use JSON;
use File::Tail;
use Getopt::Long;
use Feature::Compat::Try;
use Path::Tiny;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CVSLogwatcher::Config;


#=============================================================================
#=== GLOBAL VARIABLES                                                      ===
#=============================================================================

my ($cfg, $logger);
my %replacements = ('%d' => '' );
my $js = JSON->new()->relaxed(1);


#=============================================================================
#=== FUNCTIONS                                                             ===
#=============================================================================

#=============================================================================
# Perform token replacement in a string.
#=============================================================================

sub repl
{
  my $string = shift;

  return undef if !$string;
  for my $k (keys %replacements) {
    my $v = $replacements{$k};
    $k = quotemeta($k);
    $string =~ s/$k/$v/g;
  }
  return $string;
}


#=============================================================================
# This function adds the list of arguments into %replacements under keys
# %+0, %+1 etc. It also removes all keys that are in this form (ie. purges
# previous replacements).
#
# This is used to enable using capture groups in expect response strings.
#=============================================================================

sub repl_capture_groups
{
  #--- purge old values

  for my $key (keys %replacements) {
    if($key =~ /^%\+\d$/) {
      delete $replacements{$key};
    }
  }

  #--- add new values

  for(my $i = 0; $i < scalar(@_); $i++) {
    if($_[$i]) {
      $replacements{ sprintf('%%+%d', $i) } = $_[$i];
    }
  }
}


#=============================================================================
# Gets admin group name from hostname. Admin group is decided based on
# regexes define in "groups" top-level config object. If no match is found,
# "defgroup" key is tried under "targets"->{logid}.
#=============================================================================

sub get_admin_group
{
  #--- arguments

  my (
    $host,
    $target
  ) = @_;

  #--- do the matching

  for my $grp (keys %{$cfg->{'groups'}}) {
    for my $re_src (@{$cfg->{'groups'}{$grp}}) {
      my $re = qr/$re_src/i;
      return $grp if $host =~ /$re/;
    }
  }

  #--- if no match, try to get the default group

  if(exists $target->{'defgrp'}) {
    return $target->{'defgrp'}
  } else {
    return undef;
  }
}


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
# All of the string values can use replacement tokens (using the repl()
# function. The expect string can use capture groups, that are available to
# response strings as %+0, %+1, etc.
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

  #--- variables

  my $spawn = repl($expect_def->{'spawn'});
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

      my $chat_send = repl($row->[1]);
      my $chat_send_disp;
      my $open_log = repl($row->[2]);

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
        sprintf('[%s] Expect string(%d): %s', $logpf, $i, repl($row->[0]))
      );
      $exh->expect($cfg->{'config'}{'expmax'} // 300, '-re', repl($row->[0])) or die;
      my @g = $exh->matchlist();
      $logger->debug(
        sprintf('[%s] Expect receive(%d): %s', $logpf, $i, $exh->match())
      );
      if(@g) {
        $logger->debug(
          sprintf('[%s] Expect groups(%d): %s', $logpf, $i, join(',', @g))
        );
      }
      repl_capture_groups(@g);
      if($row->[3]) { $replacements{'%P'} = quotemeta(repl($row->[3])) };
      sleep($sleep) if $sleep;
      $logger->debug(
        sprintf('[%s] Expect send(%d): %s', $logpf, $i, repl($chat_send_disp))
      );
      $exh->print(repl($row->[1]));

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
    $cfg->{'rcs'}{'rcsco'},
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
# Try to extract hostname from configuration file; caller must supply a regex
# for the matching/extraction
#=============================================================================

sub extract_hostname
{
  my ($file, $regex) = @_;

  # read the new file
  open my $fh, $file or die "Could not open file '$file'";
  chomp( my @new_file = <$fh> );
  close $fh;

  # try to find and extract hostname
  foreach (@new_file) {
    if(/$regex/) { return $1 }
  }

  # nothing was found
  return undef;
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
    $force,             # 5. --force option
    $no_checkin,        # 6. --nocheckin option
    $mangle,            # 7. --[no]mangle option
  ) = @_;

  #--- other variables

  my $host_nodomain;    # hostname without domain
  my $group;            # administrative group
  my $sysdescr;         # system description from SNMP
  my $file;             # file holding retrieved configuration
  my $scratch;          # directory for the temporary files

  #--- scratch directory

  if($cfg->{'config'}{'tempdir'}) {
    $scratch = path($cfg->{'config'}{'tempdir'});
  } else {
    $scratch = path('.');
  }

  #--- find the target index
  # the $target argument refers to target identification, but targets are
  # actually stored in an array, so we need to find the actual item

  my ($target) = grep { $_->{'id'} eq $tid } @{$cfg->{'targets'}};
  if(!$target || !ref($target)) {
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

  if(
    $chgwho
    && exists $cfg->{'ignoreusers'}
    && grep { /^$chgwho$/ } @{$cfg->{'ignoreusers'}}
  ) {
    $logger->info(qq{[cvs/$tid] Ignored user, skipping processing});
    return;
  }

  #--- skip if ignored hosts

  # "ignorehosts" configuration object is a list of regexps that
  # if any one of them matches hostname as received from logfile,
  # causes the processing to abort; this allows to ignore certain
  # source hosts

  if(
    exists $cfg->{'ignorehosts'}
    && grep { $host =~ /$_/ } @{$cfg->{'ignorehosts'}}
  ) {
    $logger->info(qq{[cvs/$tid] Ignored host, skipping processing});
    return;
  }

  #--- get hostname without trailing domain name

  $host_nodomain = $host;
  $host_nodomain =~ s/\..*$//g;
  $replacements{'%H'} = $host_nodomain;
  $replacements{'%h'} = $host;

  #--- assign admin group

  $group = get_admin_group($host_nodomain, $target);
  if($group) {
    $logger->info(qq{[cvs/$tid] Admin group: $group});
  } else {
    $logger->error(qq{[cvs/$tid] No admin group for $host_nodomain, skipping});
    return;
  }

  #--- ensure reachability

  if($cfg->{'ping'} && system(repl($cfg->{'ping'})) >> 8) {
    $logger->error(qq{[cvs/$tid Host $host_nodomain unreachable, skipping});
    return;
  }

  #--------------------------------------------------------------------------
  #--- retrieve configuration from a device ---------------------------------
  #--------------------------------------------------------------------------

  {

  #--- default config file location, this can later be changed if we are
  #--- extracting hostname from the configuration

    $file = $scratch->child($host_nodomain);

  #--- run expect script ----------------------------------------------------

    if($target->{'expect'}) {
      run_expect_batch(
        $target->{'expect'},
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

    if(
      $mangle
      && exists $target->{'options'}
      && ref $target->{'options'}
      && (grep { $_ eq 'normeol' } @{$target->{'options'}})
    ) {
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

    if(
      $mangle
      && exists $target->{'validrange'}
      && ref $target->{'validrange'}
      && @{$target->{'validrange'}} == 2
    ) {
      if(open(FOUT, '>', "$file.validrange.$$")) {
        if(open(FIN, '<', "$file")) {
          my $in_range = defined $target->{'validrange'}[0] ? 0 : 1;
          while(my $l = <FIN>) {
            $in_range = 1
              if $l =~ $target->{'validrange'}[0];
            print FOUT $l if $in_range;
            $in_range = 0
              if defined $target->{'validrange'}[1]
              && $l =~ $target->{'validrange'}[1];
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

    if(
      $mangle
      && exists $target->{'filter'}
      && ref $target->{'filter'}
      && @{$target->{'filter'}}
    ) {
      if(open(FOUT, '>', "$file.filter.$$")) {
        if(open(FIN, '<', "$file")) {
          while(my $l = <FIN>) {
            print FOUT $l if(!(grep { $l =~ /$_/ } @{$target->{'filter'}}));
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

    if(
      exists $target->{'validate'}
      && ref $target->{'validate'}
      && @{$target->{'validate'}}
      && !defined $no_checkin
    ) {
      if(open(FIN, '<', $file)) {
        my @validate = @{$target->{'validate'}};
        while(my $l = <FIN>) {
          chomp($l);
          for(my $i = 0; $i < @validate; $i++) {
            my $re = $validate[$i];
            if($l =~ /$re/) {
              splice(@validate, $i, 1);
            }
          }
        }
        if(@validate) {
          $logger->warn("[cvs/$tid] Validation required but failed, aborting check in");
          $logger->debug(
            "[cvs/$tid] Failed validation expressions: ",
            join(', ', map { "'$_'" } @validate)
          );
          die;
        }
        close(FIN);
      }
    }

  #--- extract hostname from the configuration

  # This makes it possible to use host's own notion of hostname avoiding
  # reliance on the name that appears in syslog

    if($target->{hostname}) {
      my $selfname = extract_hostname($file, $target->{hostname});
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

    if(defined $no_checkin) {
      if($no_checkin ne '') {
        my $dst_file = $no_checkin;

        # check whether --nocheckin value specifies existing directory, if
        # it does, move the current file with its "received" filename to the
        # directory; otherwise, move the current file into specified target
        # file

        if(-d $no_checkin) {
          $no_checkin =~ s/\/+$//;
          $dst_file = $no_checkin . '/' . $host_nodomain;
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

    if(!compare_to_prev($target, $host_nodomain, $file, $repo)) {
      if($force) {
        $logger->info("[cvs/$tid] No change to current revision, but --force in effect");
      } else {
        $logger->info("[cvs/$tid] No change to current revision, skipping check-in");
        die;
      }
    }

  #--- create new revision

    $logger->debug('STEP 3');

    # is this really needed? I have no idea.
    if(-f "$repo/$host_nodomain,v") {
      $exec = sprintf(
        '%s -q -U %s/%s,v',
        $cfg->{'rcs'}{'rcsctl'},                     # rcs binary
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
      $cfg->{'rcs'}{'rcsci'},                      # rcs ci binary
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

  #--- remove the file

    if(-f "$file" && $e ne "NOREMOVE\n" ) {
      $logger->debug(qq{[cvs/$tid] Removing file $file});
      $file->remove;
    } elsif($e) {
      $logger->error(qq{[cvs/$tid] Check-in failed ($e)});
    }
  }
}



#=============================================================================
# Function to match hostname (obtained from logfile) against an array of rules
# and decide the result (MATCH or NO MATCH).
#
# A hostname is considered a rule match when all conditions in the rule are
# evaluated as matching. A hostname is considered a ruleset match when at
# least one rule results in a match.
#
# Following conditions are supported in a rule:
#
# {
#   includere => [],
#   excludere => [],
#   includelist => [],
#   excludelist => [],
# }
#
#=============================================================================

sub rule_hostname_match
{
  #--- arguments

  my (
    $group,    # 1. aref  array of rules
    $hostname  # 2. strg  hostname that is to be matched to the ruleset
  ) = @_;

  #--- sanitize arguments

  if(!ref($group)) {
    croak q{'group' argument not a reference};
  }
  if(!$hostname) {
    croak q{'hostname' argument missing};
  }

  return '' if !@$group;

  #--- iterate over the ruleset

  for my $rule (@$group) {

    my ($match_incre, $match_inclst, $match_excre, $match_exclst);

  #--- 'includere' condition

    if(exists $rule->{'includere'}) {
      for my $re (@{$rule->{'includere'}}) {
        $match_incre ||= ($hostname =~ /$re/i);
      }
    }

  #--- 'includelist' condition

    if(exists $rule->{'includelist'}) {
      for my $en (@{$rule->{'includelist'}}) {
        $match_inclst ||= (lc($hostname) eq lc($en));
      }
    }

  #--- 'excludere' condition

    if(exists $rule->{'excludere'}) {
      my $match_excre_local = 'magic';
      for my $re (@{$rule->{'excludere'}}) {
        $match_excre_local &&= ($hostname !~ /$re/i);
      }
      $match_excre = $match_excre_local eq 'magic' ? '' : $match_excre_local
    }

  #--- 'excludelist' condition

    if(exists $rule->{'excludelist'}) {
      my $match_exclst_local = 'magic';
      for my $en (@{$rule->{'excludelist'}}) {
        $match_exclst_local &&= (lc($hostname) ne lc($en));
      }
      $match_exclst = $match_exclst_local eq 'magic' ? '' : $match_exclst_local
    }

  #--- evaluate the result of current rule

    my $result = 1;

    for my $val ($match_incre, $match_inclst, $match_excre, $match_exclst) {
      if(
        defined $val
        && !$val
      ) {
        $result = '';
      }
    }

    return 1 if($result);

  #--- end of ruleset iteration

  }

  #--- default exit as FALSE

  return '';
}


#=============================================================================
# Find target based on configured conditions.
#=============================================================================

sub find_target
{
  my %arg = @_;
  my $tid;

  #--- remove domain from hostname

  if($arg{'host'}) {
    $arg{'host'} =~ s/\..*$//g;
  }

  #--- do the matching

  foreach my $target (@{$cfg->{'targets'}}) {
    # "logfile" condition
    next if
      exists $target->{'logfile'}
      && $target->{'logfile'} ne $arg{'logid'};
    # "hostmatch" condition
    next if
      exists $target->{'hostmatch'}
      && ref($target->{'hostmatch'})
      && $arg{'host'}
      && !rule_hostname_match($target->{'hostmatch'}, $arg{'host'});
    # no mismatch, so target found
    if(wantarray()) {
      return ($target->{'id'}, $target);
    } else {
      return $target->{'id'};
    }
  }
}


#=============================================================================
# Display usage help
#=============================================================================

sub help
{
  print <<EOHD;

Usage: cvs-logwatcher.pl [options]

  --help             get this information text
  --trigger=LOGID    trigger processing as if LOGID matched
  --host=HOST        define host for --trigger or limit processing to it
  --user=USER        define user for --trigger
  --msg=MSG          define message for --trigger
  --force            force check-in when using --trigger
  --nocheckin[=FILE] do not perform RCS repository check in with --trigger
  --nomangle         do not perform config text transformations
  --debug            set loglevel to debug
  --devel            development mode, implies --debug
  --initonly         init everything and exit
  --log=LOGID        only process this log

EOHD
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


#--- get command-line options ------------------------------------------------

my $cmd_trigger;
my $cmd_host;
my $cmd_user;
my $cmd_msg;
my $cmd_force;
my $cmd_help;
my $cmd_no_checkin;
my $cmd_mangle = 1;
my $cmd_debug;
my $cmd_initonly;
my $cmd_log;
my $cmd_watchonly;

if(!GetOptions(
  'trigger=s'   => \$cmd_trigger,
  'host=s'      => \$cmd_host,
  'user=s'      => \$cmd_user,
  'msg=s'       => \$cmd_msg,
  'force'       => \$cmd_force,
  'help'        => \$cmd_help,
  'nocheckin:s' => \$cmd_no_checkin,
  'mangle!'     => \$cmd_mangle,
  'debug'       => \$cmd_debug,
  'devel:s'     => sub {
                     $cmd_debug = 1;
                     $replacements{'%d'} = $_[1] || '-dev';
                   },

  # --initonly
  # Only intialize everything, but do not run the main event loop

  'initonly'    => \$cmd_initonly,

  # --log=LOGID
  # Limit processing only to this one log for testing purposes

  'log=s'       => \$cmd_log,

  # --watchonly
  # Inhibit any processing. Instead, display all lines received from logfiles
  # and indicate matches. This is meant for testing/debugging purposes.

  'watchonly'   => \$cmd_watchonly,

) || $cmd_help) {
  help();
  exit(1);
}

#--- read configuration ------------------------------------------------------

my $cfg2 = CVSLogwatcher::Config->new(config_file => "$Bin/cfg/config.json");
$cfg = $cfg2->config;

#--- read keyring ------------------------------------------------------------

for my $k (keys %{$cfg2->keyring}) {
  $replacements{$k} = $cfg2->keyring->{$k};
}

#--- initialize Log4perl logging system --------------------------------------

if(! -r 'cfg/logging.conf') {
  die "Logging configurartion 'cfg/logging.conf' not found or not readable\n";
}

Log::Log4perl->init_and_watch("cfg/logging.conf", 60);
$logger = get_logger('CVS::Main');

if($replacements{'%d'}) {
  $logger->remove_appender('AFile');
} else {
  $logger->remove_appender('AScrn');
}

if($cmd_debug) {
  $logger->level($DEBUG);
} else {
  $logger->level($INFO);
}

#--- initialize tempdir ------------------------------------------------------

{
  my $tempdir = path($Bin);
  if($cfg->{'config'}{'tempdir'}) {
    $tempdir = path($cfg->{'config'}{'tempdir'});
  }
  $replacements{'%D'} = $tempdir->absolute->stringify;
}

#--- title -------------------------------------------------------------------

$logger->info(qq{[cvs] --------------------------------});
$logger->info(qq{[cvs] NetIT CVS // Log Watcher started});
$logger->info(qq{[cvs] Mode is }, $replacements{'%d'} ? 'development' : 'production');
$logger->debug(qq{[cvs] Debugging mode enabled}) if $cmd_debug;
$logger->debug(qq{[cvs] Scratch directory is }, $replacements{'%D'});

#--- verify command-line parameters ------------------------------------------

if($cmd_trigger) {
  if(!exists $cfg->{'logfiles'}{$cmd_trigger}) {
    $logger->fatal(
      '[cvs] Option --trigger refers to non-existent logfile id, aborting'
    );
    exit(1);
  }
  if(!$cmd_host) {
    $logger->fatal(qq{[cvs] Option --trigger requires --host, aborting});
    exit(1);
  }
}


if($cmd_trigger) {
  $cmd_trigger = lc($cmd_trigger);
  $logger->info(sprintf('[cvs] Explicit target %s triggered', $cmd_trigger));
  $logger->info(sprintf('[cvs] Explicit host is %s', $cmd_host));
  $logger->info(sprintf('[cvs] Explicit user is %s', $cmd_user)) if $cmd_user;
  $logger->info(sprintf('[cvs] Explicit message is "%s"', $cmd_msg)) if $cmd_msg;
}

#-----------------------------------------------------------------------------
#--- manual check ------------------------------------------------------------
#-----------------------------------------------------------------------------

# manual run can be executed from the command line by using the
# --trigger=LOGID option. This might be used for creating the initial commit
# or for devices that cannot be triggered using logfiles. When using this mode
# --host=HOST must be used to tell which device(s) to check; --user and --msg
# should be used to specify commit author and message.

if($cmd_trigger) {

  # get list of hosts to process
  my @hosts;
  if($cmd_host =~ /^@(.*)$/) {
    my $group = $1;
    @hosts = @{$cfg->{'devgroups'}{$group}};
  } else {
    @hosts = ( $cmd_host );
  }

  # process each host
  for my $host (@hosts) {
    my $tid = find_target(
      logid => $cmd_trigger,
      host => lc($host)
    );
    if(!$tid) {
      $logger->warn("[cvs] No target found for match from '$host' in source '$cmd_trigger'");
      next;
    }
    process_match(
      $tid,
      $host,
      $cmd_msg // 'Manual check-in',
      $cmd_user // 'cvs',
      $cmd_force,
      $cmd_no_checkin,
      $cmd_mangle,
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

for my $log (keys %{$cfg->{'logfiles'}}) {

  # get log's filename; log filename can be specified both absolute (starting
  # with a slash) or relative to config.logprefix

  my $logfile = $cfg->{'logfiles'}{$log}{'filename'} // '';
  if(substr($logfile, 0, 1) ne '/') {
    $logfile = $cfg->{'config'}{'logprefix'} . $logfile;
  }

  # check if we are suppressing this logfile

  if(defined $cmd_log && $cmd_log ne $log) {
    $logger->info("[cvs] Suppressing $logfile ($log)");
    next;
  }

  # check if it is actually accessible, ignore if it is not

  next if !-r $logfile;

  # start watching the logfile

  my $h = File::Tail->new(
    name=>$logfile,
    maxinterval=>$cfg->{'config'}{'tailint'}
  );
  $h->{'cvslogwatch.logid'} = $log;
  push(@logfiles, $h);

  $logger->info("[cvs] Started observing $logfile ($log)");
}

if(scalar(@logfiles) == 0) {
  $logger->fatal(qq{[cvs] No valid logfiles defined, aborting});
  die;
}

#--- if user specifies --initonly, do not enter the main loop
#--- this is for testing purposes

if($cmd_initonly) {
  $logger->info(qq{[cvs] Init completed, exiting});
  exit(0);
}

#--- main loop

$logger->debug('[cvs] Entering main loop');
while (1) {

#--- wait for new data becoming available in any of the watched logs

  my ($nfound, $timeleft, @pending)
  = File::Tail::select(
    undef, undef, undef,
    $cfg->{'config'}{'tailmax'},
    @logfiles
  );

#--- timeout reached without any data arriving

  if(!$nfound) {
    $logger->info('[cvs] Heartbeat');
    next;
  }

#--- processing data

  foreach(@pending) {
    my $lprefix = $cfg->{'config'}{'logprefix'};
    my $tid;

    #--- get next available line
    my $l = $_->read();
    chomp($l);

    #--- get filename of the file the line is from
    my $logid = $_->{'cvslogwatch.logid'};
    die 'Assertion failed, logid missing in File::Tail handle' if !$logid;
    my $file = $cfg->{'logfiles'}{$logid}{'filename'};

    #--- if --watchonly is active, display the line
    $logger->info("[cvs/$logid] $l") if $cmd_watchonly;

    #--- match the line
    my $regex = $cfg->{'logfiles'}{$logid}{'match'};
    next if $l !~ /$regex/;

    #--- find target
    $tid = find_target(
      logid => $logid,
      host => $+{'host'}
    );

    if(!$tid) {
      $logger->warn("[cvs] No target found for match from '$+{host}' in source '$logid'");
      next;
    }

    #--- finish if --watchonly

    next if $cmd_watchonly;

    #--- start processing
    process_match(
      $tid,
      $+{'host'},
      $+{'msg'},
      $+{'user'} ? $+{'user'} : 'unknown',
      undef,
      undef,
      $cmd_mangle,
    );

  }
}
