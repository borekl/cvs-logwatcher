#!/usr/bin/perl

#=============================================================================
# CVS_CISCO
#
# Script to pull configuration log out of a Cisco device after detecting
# change by observing the device's logfile. The usual way of getting the
# config file is by configuring a transfer by setting SNMP variables and
# getting the file over TFTP.
# For IOS XR device, interactive session over SSH is used instead. Note, that
# this is done because the TFTP transfer doesn't properly use the admin
# interface in VRF, not that TFTP wouldn't be available.
# 
# (c) 2000 Expert & Partner Engineering
# (c) 2009 Alexander Leonov / Vodafone CZ
# (c) 2015 Borek Lupomesky / Vodafone CZ
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



#=============================================================================
#=== GLOBAL VARIABLES                                                      ===
#=============================================================================

my ($cfg, $logger);
my $dev               = 0;
my $prefix            = '/opt/cvs/%s';



#=============================================================================
#=== FUNCTIONS                                                             ===
#=============================================================================

#=============================================================================
# Gets admin group name from hostname.
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
    $cfg->{'logfiles'}{$logfile}{'snmp'}{'ro'},
    $cfg->{'mib'}{$oid}
  );
  
  #--- run the command

  $logger->debug(qq{[cvs-csc] Cmd: $cmd});  
  open(FH, "$cmd |") || do {
    $logger->fatal(qq{[cvs-csc] Failed to execute SNMP get ($cmd), aborting});
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
# Execute batch of expect-response pairs.
#=============================================================================

sub run_expect_batch
{
  #--- arguments
  
  my (
    $spawn,        # 1. spawn command
    $expect,       # 2. (arrayref) batch of expect-response pairs
    $sleep         # 3. optional sleep time after every command
  ) = @_;

  
  #--- spawn command
  
  $logger->info("[cvs-csc] Spawning Expect instance ($spawn)");
  my $exh = Expect->spawn($spawn) or do {
    $logger->fatal("[cvs-csc] Failed to spawn Expect instance ($spawn)");
    die;
  };
  $exh->log_stdout(0);

  eval {  #<--- eval begins here ---------------------------------------------

    for my $row (@$expect) {
      $logger->debug(
        "[cvs-csc] Expect command: " . 
        ($row->[1] eq "\r" ? '[CR]' : $row->[1])
      );
      $exh->expect(undef, '-re', $row->[0]) or die;
      $exh->print($row->[1]);
      sleep($sleep) if $sleep;
    }
  
  }; #<--- eval ends here ----------------------------------------------------

  sleep($sleep) if $sleep;  
  if($@) {
    $logger->error('[cvs-csc] Expect failed');
    $exh->soft_close();
    die;
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


#--- decide if we are development or production

$dev = 1 if abs_path($0) =~ /\/dev/;
$prefix = sprintf($prefix, $dev ? 'dev' : 'prod');

#--- read configuration

{
  local $/;
  my $fh;
  open($fh, '<', "$prefix/cfg/config.json");
  my $cfg_json = <$fh>;
  close($fh);
  $cfg = decode_json($cfg_json);
}

#--- initialize Log4perl logging system

Log::Log4perl->init("$prefix/cfg/logging.conf");
$logger = get_logger('CVS::Cisco');

#--- title

$logger->info('[cvs-csc] --------------------------------------');
$logger->info('[cvs-csc] NetIT CVS // Cisco Log Watcher started');
$logger->info('[cvs-csc] Mode is ', $dev ? 'development' : 'production');

#--- opening the logfile

my $logfile = sprintf(
                '%s/%s',
                $cfg->{'config'}{'logprefix'},
                $cfg->{'logfiles'}{'cisco'}{'logfile'}
              );
$logger->info("[cvs-csc] Opening logfile $logfile");
open(LOG, "tail -f -c 0 $logfile|");

#--- compile matching regex

my $regex_src = $cfg->{'logfiles'}{'cisco'}{'match'};
my $regex = qr/$regex_src/;

#--- logfile reading loop

while (<LOG>) {

#--- this regex triggers the processing, anything else is ignored
#--- the message being intercepted looks like the example below:

# Jun  5 10:12:10 stos20.oskarmobil.cz 1030270: Jun  5 08:12:10.109: \
# %SYS-5-CONFIG_I: Configured from console by rborelupo on vty0 \
# (172.20.113.120)

  /$regex/ && do {

    chomp;
    $logger->debug(qq{[cvs-csc] Line matched: "$_"});
    my $host = $4;
    my $message = "$1 $2 $3 $5"; 

    $logger->info(qq{[cvs-csc] Source host: $host (from syslog)});
    $logger->info('[cvs-csc] Message: ', $message);

    #--- get hostnam via SNMP
    
    # FIXME: Why messing with hostname from snmp/logfile?
    # Shouldn't it suffice to use one or another?

    $logger->info('[cvs-csc] Getting hostname from SNMP');            
    my $host2 = snmp_get_value($host, 'cisco', 'hostName');
    $host2 = $host if !$host2;
    $host2 =~ s/\..*$//;
    $logger->info(qq{[cvs-csc] Source host: $host2 (from SNMP)});
    
    $logger->info('[cvs-csc] Checking IOS version');	
    my $sysdescr = snmp_get_value($host, 'cisco', 'sysDescr');

    #--- assign admin group
    
    my $group = get_admin_group($host2, 'cisco');
    if($group) {
      $logger->info(qq{[cvs-csc] Admin group '$group'});
    } else {
      $logger->error(qq{[cvs-csc] No admin group for $host2, skipping});
      next;
    }
    
    #--- special handling for IOS XR routers
          
    # IOS XR is handled by connecting over SSH
    # apparently, this is merely done because TFTP doesn't
    # properly handle mgmt interface in an VRF.
    # On the IOS XR boxes there's "backup-config" alias defined as:
    #
    # alias backup-config copy running-config tftp://172.20.113.120/cs/<file> vrf MGMT
    #
    # where file must be host's hostname in lowercase

    my $ios_type = 'normal';
    if($sysdescr =~ /Cisco IOS XR/) {
      $logger->info(qq{[cvs-csc] IOS XR detected on $host2});
      $ios_type = 'xr';
      my $ssh_login = $cfg->{'logfiles'}{'cisco'}{'ssh_login'};
      my $ssh_pass  = $cfg->{'logfiles'}{'cisco'}{'ssh_pass'};
      my $ssh_cmd   = $cfg->{'logfiles'}{'cisco'}{'ssh_cmd'};
      my $ssh_run   = join(' ',
                        ($cfg->{'logfiles'}{'cisco'}{'ssh_run'},
                        '-l', $ssh_login, $host)
                      );
      run_expect_batch(
        $ssh_run,
        [
          [ 'password:',                   "$ssh_pass\r" ],
          [ '^RP/.*/RSP.*/CPU.*:.*NB00#$', "$ssh_cmd\r" ],
          [ 'control-c to abort',          "\r" ],
          [ 'control-c to abort',          "\r" ],
          [ '^RP/.*/RSP.*/CPU.*:.*NB00#$', "exit\r" ]
        ],
        1
      );
    }

    #--- run RCS commit
    
    my $exec = sprintf(
      '%s/bin/cvs_new_version.sh %s %s "%s" %s %s %s',
      $prefix, $host, $host2, $message, 'cisco', $group, $ios_type
    );
    
    $logger->info(qq{[cvs-csc] Running CVS script});
    $logger->debug(qq{[cvs-csc] Running command '$exec'});
    system($exec);
    $logger->info(qq{[cvs-csc] CVS script finished});
  }
    
}



