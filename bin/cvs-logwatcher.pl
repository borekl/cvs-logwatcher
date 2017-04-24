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
my $id                = '[cvs]';
my $id2;
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
# "defgroup" key is tried under "logfiles"->{logid}.
#=============================================================================

sub get_admin_group
{
  #--- arguments 

  my (
    $host,
    $logfile
  ) = @_;

  #--- do the matching
  
  for my $grp (keys $cfg->{'groups'}) {
    for my $re_src (@{$cfg->{'groups'}{$grp}}) {
      my $re = qr/$re_src/i;
      return $grp if $host =~ /$re/;
    }
  }
  
  #--- if no match, try to get the default group
  
  if(exists $cfg->{'logfiles'}{$logfile}{'defgrp'}) {
    return $cfg->{'logfiles'}{$logfile}{'defgrp'}
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
    $logfile,      # 2. logfile definition
    $oid           # 3. oid (shortname)   
  ) = @_;

  #--- make <> read the whole input at once
  
  local $/;
    
  #--- SNMP command to run
  
  my $cmd = sprintf(
    '%s -Lf /dev/null -v %d %s -c %s %s',
    $cfg->{'snmp'}{'get'},
    $cfg->{'logfiles'}{$logfile}{'snmp'}{'ver'},
    $host,
    repl($cfg->{'logfiles'}{$logfile}{'snmp'}{'ro'}),
    $cfg->{'mib'}{$oid}
  );
  
  #--- run the command

  $logger->debug(qq{$id2 Cmd: $cmd});  
  open(FH, "$cmd 2>/dev/null |") || do {
    $logger->fatal(qq{$id2 Failed to execute SNMP get ($cmd), aborting});
    die;
  };
  my $val = <FH>;
  close(FH);
  if($?) {
    $logger->debug(
      sprintf("%s SNMP get returned %d", $id2, $?)
    );
    return undef;
  }
  
  #--- parse

  $val =~ s/\R/ /mg;
  $val =~ s/^.*= STRING:\s+(.*?)\s*$/$1/;
  $val =~ s/^\"(.*)\"$/$1/;  # hostName is returned with quotes
  
  #--- finish
  
  return $val;
}



#=============================================================================
# Get system name for Cisco device.
#=============================================================================

sub snmp_get_cisco_name
{
  my $host = shift;
  my $logdef = shift;
  
  #--- first use hostName
  my $host_snmp = snmp_get_value($host, $logdef, 'hostName');
  return $host_snmp if $host_snmp;
  
  #--- if that fails, try sysName
  $host_snmp = snmp_get_value($host, $logdef, 'sysName');
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
    $expect_def,   # 1. expect conversion definitions from the config.json
    $host,         # 2. hostname
    $host_nodomain # 3. hostname without domain 
  ) = @_;
    
  #--- variables
  
  my $spawn = repl($expect_def->{'spawn'});
  my $sleep = $expect_def->{'sleep'};
  my $chat = $expect_def->{'chat'};

  #--- spawn command

  $logger->debug("$id2 Spawning Expect instance ($spawn)");
  my $exh = Expect->spawn($spawn) or do {
    $logger->fatal("$id2 Failed to spawn Expect instance ($spawn)");
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
        $logger->info("$id2 Logfile opened: ", $open_log);
      }

      #--- perform the handshake
      $logger->debug(
        sprintf('%s Expect string(%d): %s', $id2, $i, $row->[0])
      );
      $exh->expect($cfg->{'expmax'} // 300, '-re', $row->[0]) or die;
      my @g = $exh->matchlist();
      $logger->debug(
        sprintf('%s Expect receive(%d): %s', $id2, $i, $exh->match())
      );
      if(@g) {
        $logger->debug(
          sprintf('%s Expect groups(%d): %s', $id2, $i, join(',', @g))
        );
      }
      repl_capture_groups(@g);
      $logger->debug(
        sprintf('%s Expect send(%d): ', $id2, $i, repl($chat_send_disp))
      );
      $exh->print(repl($row->[1]));
      sleep($sleep) if $sleep;

      #--- next line
      $i++;
    }
  
  }; #<--- eval ends here ----------------------------------------------------

  sleep($sleep) if $sleep;  
  if($@) {
    $logger->error(qq{$id2 Expect failed});
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

  my $logdef = shift;   # logfile id  
  my $host = shift;     # host
  my $file = shift;     # file to compare
  my $repo = shift;     # repository file

  #--- other variables
  
  my ($re_src, $re_com);
  
  #--- compile regex (if any)
        
  if(exists $cfg->{'logfiles'}{$logdef}{'ignoreline'}) {
    $re_src = $cfg->{'logfiles'}{$logdef}{'ignoreline'};
    $re_com = qr/$re_src/;
  }
  $logger->debug("$id2 ", "Ignoreline regexp: $re_src");
  
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
  $logger->debug("$id2 Cmd: $exec");
  my $f_repo = read_file("$exec 2>/dev/null |", $re_com);
  return 0 if !ref($f_repo);

  #--- compare line counts

  $logger->debug("$id2 ", sprintf("Linecounts: new = %d, repo = %d", scalar(@$f_new), scalar(@$f_repo)));  
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
    $logdef,            # 1. log id
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
  
  #--- log some information
      
  $logger->info(qq{$id2 Source host: $host (from syslog)});
  $logger->info(qq{$id2 Message:     }, $msg);
  $logger->info(qq{$id2 User:        }, $chgwho) if $chgwho;

  #--- skip if ignored user
       
  # "ignoreusers" configuration object is a list of users that should
  # be ignored and no processing be done for them (this is mainly for
  # debugging purposes).
      
  if(
    $chgwho
    && exists $cfg->{'ignoreusers'}
    && $chgwho ~~ @{$cfg->{'ignoreusers'}}
  ) {
    $logger->info(qq{$id2 Ignored user, skipping processing});
    return;
  }
  
  #--- get hostname without trailing domain name
      
  $host_nodomain = $host;
  $host_nodomain =~ s/\..*$//g;
  $replacements{'%H'} = $host_nodomain;
  $replacements{'%h'} = $host;

  #--- assign admin group
      
  $group = get_admin_group($host_nodomain, $logdef);
  if($group) {
    $logger->info(qq{$id2 Admin group: $group});
  } else {
    $logger->error(qq{$id2 No admin group for $host_nodomain, skipping});
    return;
  }

  #--- ensure reachability

  if($cfg->{'ping'} && system(repl($cfg->{'ping'})) >> 8) {
    $logger->error(qq{$id2 Host $host_nodomain unreachable, skipping});
    return;
  }

  #--------------------------------------------------------------------------
  #--- Cisco ----------------------------------------------------------------
  #--------------------------------------------------------------------------

  if($logdef eq 'cisco') {
  
  #--- default platform
  
    my $platform = 'ios';

  #--- get hostname via SNMP
    
  # This is somewhat redundant and unnecessary, but for historical
  # reasons, we keep this here. The thing is that in the RCS repository
  # we use device's own hostname, retrieved with SNMP, not the name
  # from syslog entry.

    $logger->debug(qq{$id2 Getting hostname from SNMP});
    $host_snmp = snmp_get_cisco_name($host, $logdef);
    $logger->info(qq{$id2 Source host: $host_snmp (from SNMP)});
    if($host_snmp) {
      $host_nodomain = $host_snmp;
      $replacements{'%H'} = $host_snmp;
    }
  
  #--- get sysDescr (to detect OS platform)
              
    $logger->debug(qq{$id2 Checking IOS version});
    $sysdescr = snmp_get_value($host, 'cisco', 'sysDescr');
    
  #--- detect platform (IOS XR or NX-OS)
  
    my $m = $cfg->{'logfiles'}{$logdef}{'matchxr'};
    if($sysdescr =~ /$m/) { $platform = 'ios-xr'; }
    $m = $cfg->{'logfiles'}{$logdef}{'matchnxos'};
    if($sysdescr =~ /$m/) { $platform = 'nx-os'; }
    $logger->info(sprintf("%s Platform:    %s", $id2, uc($platform)));
  
  #--- IOS XR / NX-OS devices

  # bacause getting the config upon setting writeNet SNMP variable
  # doesn't work properly in IOS XR and NX-OS, we use alternate way
  # of doing things, that is loggin in over SSH and issuing a copy
  # command              

    if($platform eq 'ios-xr' || $platform eq 'nx-os') {
      run_expect_batch(
        $cfg->{'logfiles'}{$logdef}{'expect'}{$platform},
        $host, $host_nodomain
      );
    } 
    
  #--- IOS devices

  # IOS Cisco devices provide their configurations upon triggering
  # writeNet SNMP variable, which causes them to initiate TFTP upload
        
    else {
      local $/;

  #--- request config upload: assemble the command
          
      my $exec = sprintf(
        '%s -v%s -t60 -r1 -c%s %s %s.%s s %s/%s',
        $cfg->{'snmp'}{'set'},                           # snmpset binary
        $cfg->{'logfiles'}{$logdef}{'snmp'}{'ver'},      # SNMP version
        repl($cfg->{'logfiles'}{$logdef}{'snmp'}{'rw'}), # RW community
        $host,                                           # hostname
        $cfg->{'mib'}{'writeNet'},                       # writeNet OID
        $cfg->{'config'}{'src-ip'},                      # source IP addr
        repl($cfg->{'config'}{'tftpdir'}),               # TFTP subdir
        $host_nodomain                                   # TFTP filename
      );
      $logger->debug(qq{$id2 Cmd: }, $exec);

  #--- request config upload: perform the command
          
      open(my $fh, '-|', $exec) || do {
        $logger->fatal(qq{$id2 Failed to request config ($exec)});
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
    run_expect_batch(
      $cfg->{'logfiles'}{$logdef}{'expect'},
      $host, $host_nodomain
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
        "$id2 File $file does not exist, skipping further processing"
      );
      die;
    } else {
      $logger->info(
        sprintf('%s File %s received, %d bytes', $id2, $file, -s $file )
      );
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
      
    if(!compare_to_prev($logdef, $host_nodomain, $file, $repo)) {
      if($force) {
        $logger->info("$id2 No change to current revision, but --force in effect");
      } else {
        $logger->info("$id2 No change to current revision, skipping check-in");
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
      $logger->debug("$id2 Cmd: $exec");
      $rv = system($exec);
      if($rv) {
        $logger->error("$id2 Cmd failed with: ", $rv);
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
    $logger->debug("$id2 Cmd: $exec");
    $rv = system($exec);
    if($rv) {
      $logger->error("$id2 Cmd failed with: ", $rv);
      die;
    }

    $logger->info(qq{$id2 CVS check-in completed successfully});

  #--- end of eval ----------------------------------------------------------

  };

  #--- remove the file

  if(-f "$tftpdir/$host_nodomain" ) {
    $logger->debug(qq{$id2 Removing file $tftpdir/$host_nodomain});
    unlink("$tftpdir/$host_nodomain");
  }
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


#--- get command-line options

my $cmd_trigger;
my $cmd_host;
my $cmd_user;
my $cmd_msg;
my $cmd_force;
my $cmd_help;

if(!GetOptions(
  'trigger=s' => \$cmd_trigger,
  'host=s'    => \$cmd_host,
  'user=s'    => \$cmd_user,
  'msg=s'     => \$cmd_msg,
  'force'     => \$cmd_force,
  'help'      => \$cmd_help
) || $cmd_help) {
  help();
  exit(1);
}

#--- decide if we are development or production

$dev = 1 if abs_path($0) =~ /\/dev/;
$prefix = sprintf($prefix, $dev ? 'dev' : 'prod');
$replacements{'%d'} = ($dev ? '-dev' : '');

#--- read configuration

{
  local $/;
  my $fh;
  open($fh, '<', "$prefix/cfg/config.json") or die;
  my $cfg_json = <$fh>;
  close($fh);
  $cfg = $js->decode($cfg_json) or die;
}

#--- read keyring

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

#--- initialize Log4perl logging system

Log::Log4perl->init_and_watch("$prefix/cfg/logging.conf", 60);
$logger = get_logger('CVS::Main');

#--- initialize tftpdir variable

$tftpdir = $cfg->{'config'}{'tftproot'};
$tftpdir .= '/' . $cfg->{'config'}{'tftpdir'} if $cfg->{'config'}{'tftpdir'};
$tftpdir = repl($tftpdir);
$replacements{'%T'} = $tftpdir;
$replacements{'%t'} = repl($cfg->{'config'}{'tftpdir'});

#--- source address

$replacements{'%i'} = $cfg->{'config'}{'src-ip'};

#--- title

$logger->info(qq{$id --------------------------------});
$logger->info(qq{$id NetIT CVS // Log Watcher started});
$logger->info(qq{$id Mode is }, $dev ? 'development' : 'production');
$logger->info(qq{$id Tftp dir is $tftpdir});

#--- verify command-line parameters

if($cmd_trigger) {
  if(grep { $_ eq lc($cmd_trigger) } keys %{$cfg->{'logfiles'}}) {
    if(!$cmd_host) {
      $logger->fatal(qq{$id No target host defined, aborting});
      exit(1);
    }
  } else {
    $logger->fatal(qq{$id --trigger refers to non-existent log id, aborting});
    exit(1);
  }
}
if($cmd_trigger) {
  $cmd_trigger = lc($cmd_trigger);
  $logger->info(sprintf('%s Explicit target %s triggered', $id, $cmd_trigger));
  $logger->info(sprintf('%s Explicit host is %s', $id, $cmd_host));
  $logger->info(sprintf('%s Explicit user is %s', $id, $cmd_user)) if $cmd_user;
  $logger->info(sprintf('%s Explicit message is "%s"', $id, $cmd_msg)) if $cmd_msg;
}

#--- manual check

# manual run can be executed from the command line by using the
# --trigger=LOGID option. This might be used for creating the initial commit
# or for devices that cannot be triggered using logfiles. When using this mode
# --host=HOST must be used to tell which device to check; --user and --msg
# should be used to specify commit author and message.

if($cmd_trigger) {
  $id2 = sprintf('[cvs/%s]', $cmd_trigger);

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
    process_match(
      $cmd_trigger,
      $host,
      $cmd_msg // 'Manual check-in',
      $cmd_user // 'cvs',
      $cmd_force
    );
  }

  # exit
  $logger->info("$id2 Finishing");
  exit(0);
}

#--- initializing the logfiles

my @logfiles;
for my $lf (keys %{$cfg->{'logfiles'}}) {
  my $lfpath = sprintf(
    '%s/%s',
    $cfg->{'config'}{'logprefix'},
    $cfg->{'logfiles'}{$lf}{'logfile'}
  );
  push(
    @logfiles, 
    File::Tail->new(
      name=>$lfpath,
      maxinterval=>$cfg->{'config'}{'tailint'}
    )
  );
}
if(scalar(@logfiles) == 0) { 
  $logger->fatal(qq{$id No logfiles defined, aborting});
  die; 
}

#--- main loop

$logger->debug($id, ' Entering main loop');
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
    
    #--- get next available line
    my $l = $_->read();
    chomp($l);
    
    #--- get filename of the file the line is from
    my $file = $_->{'input'};
    $file =~ s/^$lprefix\///g;
    
    #--- get the log id
    my ($logdef) = grep { 
      $file eq $cfg->{'logfiles'}{$_}{'logfile'} 
    } (keys %{$cfg->{'logfiles'}});
    if(!$logdef) { 
      $logger->fatal("[cvs] No log id found for '$file', aborting'");
      die "No log id found for '$file'!";
    }
    $id2 = sprintf('[cvs/%s]', $logdef);
    
    #--- match the line
    my $regex = $cfg->{'logfiles'}{$logdef}{'match'};
    $l =~ /$regex/ && do {
      $logger->debug("$id2 $l");

      # ignore hosts if --host is specified
      if(!$cmd_trigger && $cmd_host) {
        if($+{'host'} !~ /^$cmd_host\./i) {
          $logger->info(
            sprintf("%s Ignoring host %s (--host)", $id2, $+{'host'})
          );
          next;
        }
      }

      # start processing
      process_match(
        $logdef, 
        $+{'host'}, 
        $+{'msg'}, 
        $+{'user'} ? $+{'user'} : 'unknown'
      );
    };
  }

}
    
