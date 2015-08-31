#!/usr/bin/perl

#=============================================================================
# CVS LOG WATCHER
#
# Script to pull configuration log out of a network device after detecting
# change by observing the device's logfile. The usual way of getting the
# config file is by configuring a transfer by setting SNMP variables and
# getting the file over TFTP.
# For IOS XR device, interactive session over SSH is used instead. Note, that
# this is done because the TFTP transfer doesn't properly use the admin
# interface in VRF, not that TFTP wouldn't be available.
# 
# (c) 2000 Expert & Partner Engineering
# (c) 2009 Alexander Leonov / Vodafone CZ
# (c) 2015 Borek Lupomesky / Vodafone CZ (mostly rewritten)
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
    $string =~ s/$k/$v/g;
  }
  return $string;
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
    '%s -v %d %s -c %s %s',
    $cfg->{'snmp'}{'get'},
    $cfg->{'logfiles'}{$logfile}{'snmp'}{'ver'},
    $host,
    repl($cfg->{'logfiles'}{$logfile}{'snmp'}{'ro'}),
    $cfg->{'mib'}{$oid}
  );
  
  #--- run the command

  $logger->debug(qq{$id2 Cmd: $cmd});  
  open(FH, "$cmd |") || do {
    $logger->fatal(qq{$id2 Failed to execute SNMP get ($cmd), aborting});
    die;
  };
  my $val = <FH>;
  close(FH);
  
  #--- parse

  $val =~ s/\R/ /mg;
  $val =~ s/^.*= STRING:\s"(.*)".*$/$1/;

  #--- finish
  
  return $val;
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
      $logger->debug("$id2 Expect command: " . $chat_send_disp);
      $exh->expect(undef, '-re', $row->[0]) or die;
      $exh->print(repl($row->[1]));
      sleep($sleep) if $sleep;
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
# Display usage help
#=============================================================================

sub help
{
  print "Usage: cvs-logwatcher.pl [options]\n\n";
  print "  --help            get this information text\n";
  print "  --trigger=LOGID   trigger processing as if LOGID matched\n";
  print "  --host=HOST       define host for --trigger\n";
  print "  --user=USER       define user for --trigger\n";
  print "  --msg=MSG         define message for --trigger\n";
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

if(!GetOptions(
  'trigger=s' => \$cmd_trigger,
  'host=s'    => \$cmd_host,
  'user=s'    => \$cmd_user,
  'msg=s'     => \$cmd_msg
)) {
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
  $cfg = decode_json($cfg_json) or die;
}

#--- read keyring

if(exists $cfg->{'config'}{'keyring'}) {
  local $/;
  my ($fh, $krg);
  open($fh, '<', "$prefix/cfg/" . $cfg->{'config'}{'keyring'}) or die;
  my $krg_json = <$fh>;
  close($fh);
  $krg = decode_json($krg_json) or die;
  for my $k (keys %$krg) {
    $replacements{$k} = $krg->{$k};
  }
}

#--- initialize Log4perl logging system

Log::Log4perl->init_and_watch("$prefix/cfg/logging.conf", 60);
$logger = get_logger('CVS::Main');

#--- initialze tftpdir variable

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
$cmd_trigger = lc($cmd_trigger);
$logger->info(sprintf('%s Explicit target %s triggered', $id, $cmd_trigger));
$logger->info(sprintf('%s Explicit host is %s', $id, $cmd_host));
$logger->info(sprintf('%s Explicit user is %s', $id, $cmd_user)) if $cmd_user;
$logger->info(sprintf('%s Explicit message is "%s"', $id, $cmd_msg)) if $cmd_msg;

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
      $logger->fatal(qq{[cvs] No log id found for '$file', aborting'});
      die "No log id found for '$file'!"; 
    }
    $id2 = sprintf('[cvs/%s]', $logdef);
    
    #--- match the line
    my $regex = $cfg->{'logfiles'}{$logdef}{'match'};
    $l =~ /$regex/ && do {

#----------------------------------------------------------------------------
#--- generic ----------------------------------------------------------------
#----------------------------------------------------------------------------

#--- basic data processing
        
      $logger->debug("$id2 $l");
      my ($host, $message, $chgwho) = ( $+{'host'}, $+{'msg'}, $+{'user'} );
      $replacements{'%h'} = $host;
      
#--- log some information
      
      $logger->info(qq{$id2 Source host: $host (from syslog)});
      $logger->info(qq{$id2 Message:     }, $message);
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
        next;
      }
      
#--- get hostname without trailing domain name
      
      my $host_nodomain = $host;
      $host_nodomain =~ s/\..*$//g;
      $replacements{'%H'} = $host_nodomain;
      
#--- assign admin group
      
      my $group = get_admin_group($host_nodomain, $logdef);
      if($group) {
        $logger->info(qq{$id2 Admin group '$group'});
      } else {
        $logger->error(qq{$id2 No admin group for $host_nodomain, skipping});
        next;
      }
        
#----------------------------------------------------------------------------
#--- Cisco ------------------------------------------------------------------
#----------------------------------------------------------------------------

      if($logdef eq 'cisco') {

        #--- get hostname via SNMP

# This is somewhat redundant and unnecessary, but for historical
# reasons, we keep this here. The thing is that in the RCS repository
# we use device's own hostname, retrieved with SNMP, not the name
# from syslog entry.

        $logger->info(qq{$id2 Getting hostname from SNMP});
        my $host_snmp = snmp_get_value($host, 'cisco', 'hostName');
        $host_snmp =~ s/\..*$//;
        $logger->info(qq{$id2 Source host: $host_snmp (from SNMP)});
        if($host_snmp) {
          $host_nodomain = $host_snmp;
          $replacements{'%H'} = $host_snmp;
        }

#--- get sysDescr (to detect IOS XR)
              
        $logger->info(qq{$id2 Checking IOS version});
        my $sysdescr = snmp_get_value($host, 'cisco', 'sysDescr');

#--- special handling for IOS XR routers
              
# IOS XR is handled by connecting over SSH
# apparently, this is merely done because TFTP doesn't
# properly handle mgmt interface in an VRF.
# On the IOS XR boxes there's "backup-config" alias defined as:
#
# alias backup-config copy running-config tftp://172.20.113.120/cs/<file> vrf MGMT
#
# where file must be host's hostname in lowercase

        my $xrre = $cfg->{'logfiles'}{$logdef}{'matchxr'};
        if($sysdescr =~ /$xrre/) {
          $logger->info(qq{$id2 IOS XR detected on $host_nodomain});
          run_expect_batch(
            $cfg->{'logfiles'}{$logdef}{'expect'},
            $host, $host_nodomain
          );
        } 
        
#--- non-IOS XR devices

# Non-IOS XR Cisco devices provide their configurations upon triggering
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

          my $file = sprintf(
            '%s/%s', 
            $tftpdir, 
            $host_nodomain
          );
          
        }
      }

#----------------------------------------------------------------------------
#--- non-Cisco devices ------------------------------------------------------
#----------------------------------------------------------------------------

      else {
        run_expect_batch(
          $cfg->{'logfiles'}{$logdef}{'expect'},
          $host, $host_nodomain
        );
      }

#----------------------------------------------------------------------------
#--- RCS check-in -----------------------------------------------------------
#----------------------------------------------------------------------------

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
        next;
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
      
      eval {
        
        my (@f_new, @f_repo);
        my ($re_src, $re_com);
        
#--- compile regex (if any)
        
        if(exists $cfg->{'logfiles'}{$logdef}{'ignoreline'}) {
          $re_src = $cfg->{'logfiles'}{$logdef}{'ignoreline'};
          $re_com = qr/$re_src/;
        }
        
#--- read the newly obtained config file
        
        open(my $fh_new, $file) 
          or die "Failed to open the new file\n";
        while(<$fh_new>) {
          chomp;
          next if $re_src && /$re_com/;
          push(@f_new, $_);
        }
        close($fh_new);
        
#--- read the most recent CVS version

        $exec = sprintf(
          '%s -q -p %s/%s,v',
          $cfg->{'rcs'}{'rcsco'},
          $repo,
          $host_nodomain
        );
        $logger->debug("$id2 Cmd: $exec");
        open(my $fh_repo, "$exec |") 
          or die "Failed to open the last CVS revision\n";
        while(<$fh_repo>) {
          chomp;
          next if $re_src && /$re_com/;
          push(@f_repo, $_);
        }
        close($fh_repo);
        
#--- compare line counts
        
        if(scalar(@f_new) != scalar(@f_repo)) {
          die "OK\n"
        }
        
#--- compare contents
        
        for(my $i = 0; $i < scalar(@f_new); $i++) {
          if($f_new[$i] ne $f_repo[$i]) {
            die "OK\n";
          }
        }
        
      };
      if($@) {
        chomp($@);
        if($@ ne "OK") {
          $logger->fatal("$id2 Failed to compare revisions ($@)");
          next;
        }
      } else {
        $logger->info("$id2 No change to current revision, skipping check-in");
        unlink($file);
        next;
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
          next;
        }
      }      
        
      $exec = sprintf(
        '%s -q "-m%s" -t-%s %s/%s %s/%s,v',
        $cfg->{'rcs'}{'rcsci'},                      # rcs ci binary
        $message,                                    # commit message
        $host,                                       # file description
        $tftpdir,                                    # tftp directory
        $host_nodomain,                              # config from device
        $repo, $host_nodomain                        # config in repo
      );
      $logger->debug("$id2 Cmd: $exec");
      $rv = system($exec);
      if($rv) {
        $logger->error("$id2 Cmd failed with: ", $rv);
        next;
      }
      
      $logger->info(qq{$id2 CVS check-in completed successfully});
    }
  }
  
}
  
