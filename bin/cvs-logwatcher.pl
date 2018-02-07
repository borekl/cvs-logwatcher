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
use Cwd qw(abs_path);
use Log::Log4perl qw(get_logger);
use JSON;
use File::Tail;
use Getopt::Long;


#=============================================================================
#=== GLOBAL VARIABLES                                                      ===
#=============================================================================

my ($cfg, $logger);
my $dev               = 0;
my $prefix            = '/opt/cvs/%s';
my $tftpdir;
my %replacements;
my $js                = JSON->new()->relaxed(1);


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
  
  for my $grp (keys $cfg->{'groups'}) {
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
# Get single value from a specific SNMP OID. At this moment it only reads
# string variables.
#=============================================================================

sub snmp_get_value
{
  #--- arguments 
  
  my (
    $host,         # 1. hostname
    $target,       # 2. target definition
    $oid,          # 3. oid (shortname)
    $logpf,        # 4. log prefix
  ) = @_;

  #--- make <> read the whole input at once
  
  local $/;
    
  #--- SNMP command to run
  
  my $cmd = sprintf(
    '%s -Lf /dev/null -v %s %s %s %s',
    $cfg->{'snmp'}{'get'},
    ($target->{'snmp'}{'ver'} // '1'),
    $host,
    $target->{'snmp'}{'ro'} ? '-c ' . repl($target->{'snmp'}{'ro'}) : '',
    $cfg->{'mib'}{$oid}
  );
  
  #--- run the command

  $logger->debug(qq{[$logpf] Cmd: $cmd});
  open(FH, "$cmd 2>/dev/null |") || do {
    $logger->fatal(qq{[$logpf] Failed to execute SNMP get ($cmd), aborting});
    die;
  };
  my $val = <FH>;
  close(FH);
  if($?) {
    $logger->debug(
      sprintf("[%s] SNMP get returned %d", $logpf, $?)
    );
    return undef;
  }
  
  #--- parse

  $val =~ s/\R/ /mg;
  $val =~ s/^.*= STRING:\s+(.*?)\s*$/$1/;
  $val =~ s/^\"(.*)\"$/$1/;  # hostName is returned with quotes

  $val = undef if $val =~ /= No Such Object/;

  #--- finish
  
  return $val;
}



#=============================================================================
# Get system name for a device. This is done by first trying 'hostName' and if
# that fails then tries 'sysName'.
#=============================================================================

sub snmp_get_system_name
{
  my (
    $host,
    $target,
    $logpf,
  ) = @_;
  
  #--- first use hostName
  my $host_snmp = snmp_get_value($host, $target, 'hostName', $logpf);
  return $host_snmp if $host_snmp;
  
  #--- if that fails, try sysName
  $host_snmp = snmp_get_value($host, $target, 'sysName', $logpf);
  if($host_snmp) {
    $host_snmp =~ s/\..*$//;
    return $host_snmp;
  }

  #--- otherwise fail  
  return undef;
}



#=============================================================================
# Execute batch of expect-response pairs. If there's third value in the 
# arrayref containing the exp-resp pair, it will be taken as a file to
# begin logging into.
#=============================================================================

sub run_expect_batch
{
  #--- arguments
  
  my (
    $expect_def,    # 1. expect conversion definitions from the config.json
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
    die;
  };
  $exh->log_stdout(0);

  eval {  #<--- eval begins here ---------------------------------------------

    my $i = 1;
    for my $row (@$chat) {
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
        sprintf('[%s] Expect string(%d): %s', $logpf, $i, $row->[0])
      );
      $exh->expect($cfg->{'config'}{'expmax'} // 300, '-re', $row->[0]) or die;
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
      $logger->debug(
        sprintf('[%s] Expect send(%d): %s', $logpf, $i, repl($chat_send_disp))
      );
      $exh->print(repl($row->[1]));
      sleep($sleep) if $sleep;

      #--- next line
      $i++;
    }
  
  }; #<--- eval ends here ----------------------------------------------------

  sleep($sleep) if $sleep;  
  if($@) {
    $logger->error(qq{[$logpf] Expect failed});
    $exh->soft_close();
    die;
  } else {
    $exh->soft_close();
  }
}



#=============================================================================
# Read file into array of lines
#=============================================================================

sub read_file
{
  my $file = shift;
  my $regex = shift;
  my @re;
  
  open(my $fh, $file) or return undef;
  while(<$fh>) {
    chomp;
    next if $regex && /$regex/;
    push(@re, $_);
  }
  close($fh);

  return \@re;
}



#=============================================================================
# Compare a file with its last revision in CVS and return true if there is a
# difference.
#=============================================================================

sub compare_to_prev
{
  #--- arguments

  my $target = shift;   # target
  my $host = shift;     # host
  my $file = shift;     # file to compare
  my $repo = shift;     # repository file

  #--- other variables
  
  my ($re_src, $re_com);
  my $logpf = '[cvs/' . $target->{'id'}  . ']';
  
  #--- compile regex (if any)
        
  if(exists $target->{'ignoreline'}) {
    $re_src = $target->{'ignoreline'};
    $re_com = qr/$re_src/;
  }
  $logger->debug("$logpf Ignoreline regexp: ", $re_src);
  
  #--- read the new file
  
  my $f_new = read_file($file, $re_com);
  return 0 if !ref($f_new);
  
  #--- read the most recent CVS version

  my $exec = sprintf(
    '%s -q -p %s/%s,v',
    $cfg->{'rcs'}{'rcsco'},
    $repo,
    $host
  );
  $logger->debug("$logpf Cmd: $exec");
  my $f_repo = read_file("$exec 2>/dev/null |", $re_com);
  return 0 if !ref($f_repo);

  #--- compare line counts

  $logger->debug("$logpf ", sprintf("Linecounts: new = %d, repo = %d", scalar(@$f_new), scalar(@$f_repo)));
  if(scalar(@$f_new) != scalar(@$f_repo)) {
    return 1;
  }
  
  #--- compare contents
        
  for(my $i = 0; $i < scalar(@$f_new); $i++) {
    if($f_new->[$i] ne $f_repo->[$i]) {
      return 1;
    }
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
    $chgwho,            # 3. username
    $force              # 4. --force option
  ) = @_;
  
  #--- other variables
  
  my $host_nodomain;    # hostname without domain
  my $host_snmp;        # hostname from SNMP
  my $group;            # administrative group
  my $sysdescr;         # system description from SNMP
  
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
  # be ignored and no processing be done for them (this is mainly for
  # debugging purposes).
      
  if(
    $chgwho
    && exists $cfg->{'ignoreusers'}
    && $chgwho ~~ @{$cfg->{'ignoreusers'}}
  ) {
    $logger->info(qq{[cvs/$tid] Ignored user, skipping processing});
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
  #--- Cisco ----------------------------------------------------------------
  #--------------------------------------------------------------------------

  if($tid eq 'cisco') {
  
  #--- default platform
  
    my $platform = 'ios';

  #--- get hostname via SNMP
    
  # This is somewhat redundant and unnecessary, but for historical
  # reasons, we keep this here. The thing is that in the RCS repository
  # we use device's own hostname, retrieved with SNMP, not the name
  # from syslog entry.

    $logger->debug(qq{[cvs/cisco] Getting hostname from SNMP});
    $host_snmp = snmp_get_system_name($host, $target, 'cvs/cisco');
    $logger->info(qq{[cvs/cisco] Source host: $host_snmp (from SNMP)});
    if($host_snmp) {
      $host_nodomain = $host_snmp;
      $replacements{'%H'} = $host_snmp;
    }
  
  #--- get sysDescr (to detect OS platform)
              
    $logger->debug(qq{[cvs/cisco] Checking IOS version});
    $sysdescr = snmp_get_value($host, $target, 'sysDescr', 'cvs/cisco');
    
  #--- detect platform (IOS XR or NX-OS)
  
    my $m = $target->{'matchxr'};
    if($sysdescr =~ /$m/) { $platform = 'ios-xr'; }
    $m = $target->{'matchnxos'};
    if($sysdescr =~ /$m/) { $platform = 'nx-os'; }
    $logger->info(sprintf("[cvs/cisco] Platform:    %s", uc($platform)));
  
  #--- IOS XR / NX-OS devices

  # bacause getting the config upon setting writeNet SNMP variable
  # doesn't work properly in IOS XR and NX-OS, we use alternate way
  # of doing things, that is loggin in over SSH and issuing a copy
  # command              

    if($platform eq 'ios-xr' || $platform eq 'nx-os') {
      run_expect_batch(
        $target->{'expect'}{$platform},
        $host, $host_nodomain,
        'cvs/cisco'
      );
    } 
    
  #--- IOS devices

  # IOS Cisco devices provide their configurations upon triggering
  # writeNet SNMP variable, which causes them to initiate TFTP upload
        
    else {
      local $/;

  #--- request config upload: assemble the command
          
      my $exec = sprintf(
        '%s -Lf /dev/null -v%s -t60 -r1 -c%s %s %s.%s s %s/%s',
        $cfg->{'snmp'}{'set'},                           # snmpset binary
        $target->{'snmp'}{'ver'},                        # SNMP version
        repl($target->{'snmp'}{'rw'}),                   # RW community
        $host,                                           # hostname
        $cfg->{'mib'}{'writeNet'},                       # writeNet OID
        $cfg->{'config'}{'src-ip'},                      # source IP addr
        repl($cfg->{'config'}{'tftpdir'}),               # TFTP subdir
        $host_nodomain                                   # TFTP filename
      );
      $logger->debug(qq{[cvs/cisco] Cmd: }, $exec);

  #--- request config upload: perform the command
          
      open(my $fh, '-|', $exec) || do {
        $logger->fatal(qq{[cvs/cisco] Failed to request config ($exec)});
        next;
      };
      <$fh>;
      close($fh);
    }
  }

  #--------------------------------------------------------------------------
  #--- non-Cisco devices ----------------------------------------------------
  #--------------------------------------------------------------------------

  else {

  #--- "snmphost" option ----------------------------------------------------

  # This option triggers retrieval of SNMP hostName value from the device
  # which is then used as a filename to check the config as. Intended as a
  # way to use proper capitalization of hostname.

    if(
      exists $target->{'options'}
      && ref $target->{'options'}
      && (grep { $_ eq 'snmphost' } @{$target->{'options'}})
    ) {
      my $snmp_host = snmp_get_system_name($host, $target, "cvs/$tid");
      if($snmp_host) {
        $host_nodomain = $snmp_host;
        $replacements{'%H'} = $snmp_host;
        $logger->info(qq{[cvs/$tid] Source host: $snmp_host (from SNMP)});
      } else {
        $logger->warn(qq{[cvs/$tid] Failed to get hostname via SNMP});
      }
    }

  #--- run expect script ----------------------------------------------------

    run_expect_batch(
      $target->{'expect'},
      $host, $host_nodomain,
      "cvs/$tid"
    );
  }

  #--------------------------------------------------------------------------

  eval {

  #--------------------------------------------------------------------------
  #--- RCS check-in ---------------------------------------------------------
  #--------------------------------------------------------------------------

    my ($exec, $rv);
    my $file = "$tftpdir/$host_nodomain";
    my $repo = sprintf(
      '%s/%s/%s', $prefix, $cfg->{'rcs'}{'rcsrepo'}, $group
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

  #--- filter out junk at the start and at the end ("validrange")

  # If "validrange" is specified for a target, then the first item in it
  # specifies regex for the first valid line of the config and the second
  # item specifies regex for the last valid line.  Either regex can be
  # undefined which means the config range starts on the first line/ends on
  # the last line.  This allows filtering junk that is saved with the config
  # (echo of the chat commands, disconnection message etc.)

    if(
      exists $target->{'validrange'}
      && ref $target->{'validrange'}
      && @{$target->{'validrange'}} == 2
    ) {
      if(open(FOUT, '>', "$file.$$")) {
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
              "[cvs/$tid] Config reduced from %s to %s bytes (validrange)",
              -s $file, -s "$file.$$"
            )
          );
          rename("$file.$$", $file);
        }
        close(FOUT);
      }
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
      '%s -q -w%s "-m%s" -t-%s %s/%s %s/%s,v',
      $cfg->{'rcs'}{'rcsci'},                      # rcs ci binary
      $chgwho,                                     # author
      $msg,                                        # commit message
      $host,                                       # file description
      $tftpdir,                                    # tftp directory
      $host_nodomain,                              # config from device
      $repo, $host_nodomain                        # config in repo
    );
    $logger->debug("[cvs/$tid] Cmd: $exec");
    $rv = system($exec);
    if($rv) {
      $logger->error("[cvs/$tid] Cmd failed with: ", $rv);
      die;
    }

    $logger->info(qq{[cvs/$tid] CVS check-in completed successfully});

  #--- end of eval ----------------------------------------------------------

  };

  #--- remove the file

  if(-f "$tftpdir/$host_nodomain" ) {
    $logger->debug(qq{[cvs/$tid] Removing file $tftpdir/$host_nodomain});
    unlink("$tftpdir/$host_nodomain");
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
    $tid = $target->{'id'};
    last;
  }

  return $tid;
}


#=============================================================================
# Display usage help
#=============================================================================

sub help
{
  print "Usage: cvs-logwatcher.pl [options]\n\n";
  print "  --help            get this information text\n";
  print "  --trigger=LOGID   trigger processing as if LOGID matched\n";
  print "  --host=HOST       define host for --trigger or limit processing to it\n";
  print "  --user=USER       define user for --trigger\n";
  print "  --msg=MSG         define message for --trigger\n";
  print "  --force           force check-in when using --trigger\n";
  print "  --snmp-name       request SNMP hostName for given host/trigger and exit\n";
  print "\n";
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
my $cmd_snmp_name;

if(!GetOptions(
  'trigger=s' => \$cmd_trigger,
  'host=s'    => \$cmd_host,
  'user=s'    => \$cmd_user,
  'msg=s'     => \$cmd_msg,
  'force'     => \$cmd_force,
  'help'      => \$cmd_help,
  'snmp-name' => \$cmd_snmp_name,
) || $cmd_help) {
  help();
  exit(1);
}

#--- decide if we are development or production ------------------------------

$dev = 1 if abs_path($0) =~ /\/dev/;
$prefix = sprintf($prefix, $dev ? 'dev' : 'prod');
$replacements{'%d'} = ($dev ? '-dev' : '');

#--- read configuration ------------------------------------------------------

{
  local $/;
  my $fh;
  open($fh, '<', "$prefix/cfg/config.json") or die;
  my $cfg_json = <$fh>;
  close($fh);
  $cfg = $js->decode($cfg_json) or die;
}

#--- read keyring ------------------------------------------------------------

if(exists $cfg->{'config'}{'keyring'}) {
  local $/;
  my ($fh, $krg);
  open($fh, '<', "$prefix/cfg/" . $cfg->{'config'}{'keyring'}) or die;
  my $krg_json = <$fh>;
  close($fh);
  $krg = $js->decode($krg_json) or die;
  for my $k (keys %$krg) {
    $replacements{$k} = $krg->{$k};
  }
}

#--- initialize Log4perl logging system --------------------------------------

Log::Log4perl->init_and_watch("$prefix/cfg/logging.conf", 60);
$logger = get_logger('CVS::Main');

#--- initialize tftpdir variable ---------------------------------------------

$tftpdir = $cfg->{'config'}{'tftproot'};
$tftpdir .= '/' . $cfg->{'config'}{'tftpdir'} if $cfg->{'config'}{'tftpdir'};
$tftpdir = repl($tftpdir);
$replacements{'%T'} = $tftpdir;
$replacements{'%t'} = repl($cfg->{'config'}{'tftpdir'});

#--- source address ----------------------------------------------------------

$replacements{'%i'} = $cfg->{'config'}{'src-ip'};

#--- title -------------------------------------------------------------------

$logger->info(qq{[cvs] --------------------------------});
$logger->info(qq{[cvs] NetIT CVS // Log Watcher started});
$logger->info(qq{[cvs] Mode is }, $dev ? 'development' : 'production');
$logger->info(qq{[cvs] Tftp dir is $tftpdir});

#--- verify command-line parameters ------------------------------------------

if($cmd_trigger) {
  if(grep { $_->{'id'} eq lc($cmd_trigger) } @{$cfg->{'targets'}}) {
    if(!$cmd_host) {
      $logger->fatal(qq{[cvs] No target host defined, aborting});
      exit(1);
    }
  } else {
    $logger->fatal(qq{[cvs] --trigger refers to non-existent target id, aborting});
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
#--- SNMP name check ---------------------------------------------------------
#-----------------------------------------------------------------------------

# The --snmp-name allows to check what name given --host/--trigger reports
# back, primarily for troubleshooting purposes.

if($cmd_snmp_name) {
  if($cmd_host && $cmd_trigger) {
    my $tid = find_target(host => $cmd_host, logid => $cmd_trigger);
    my ($target) = grep { $_->{'id'} eq $tid } @{$cfg->{'targets'}};
    if(!$target) {
      $logger->fatal("[cvs] No target found for host $cmd_host and log $cmd_trigger");
    } else {
      my $snmp_host = snmp_get_system_name($cmd_host, $target, 'cvs');
      if(!$snmp_host) {
        $logger->fatal("[cvs/$tid] No response for SNMP hostName query");
      } else {
        $logger->info("[cvs/$tid] SNMP hostName query returned '$snmp_host'");
      }
    }
  } else {
    $logger->fatal('[cvs] --host and --trigger must be given with --snmp-host');
  }
  exit(0);
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
      $cmd_force
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
  if(substr($logfile,0,1) ne '/') {
    $logfile = $cfg->{'config'}{'logprefix'} . $logfile;
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

  $logger->debug("[cvs] Started observing $logfile ($log)");
}

if(scalar(@logfiles) == 0) { 
  $logger->fatal(qq{[cvs] No valid logfiles defined, aborting});
  die; 
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

    #--- start processing
    process_match(
      $tid,
      $+{'host'},
      $+{'msg'},
      $+{'user'} ? $+{'user'} : 'unknown'
    );

  }
}
    
