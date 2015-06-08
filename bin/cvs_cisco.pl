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


#=== modules and pragmas =====================================================

use strict;
use warnings;
use Expect;
use Cwd qw(abs_path);


#=== variables and configuration =============================================

my $dev               = 0;
my $prefix            = '/opt/cvs/%s';
my $cisco_logfile     = "/var/log/cisco_all.log";
my $logfile           = "/var/log/cvs_cisco.log";
my $myip              = "172.20.113.120";
my $myip_new_external = "217.77.161.62";
my $mib_config        = ".1.3.6.1.4.1.9.2.1.55";
my $mib_hostname      = ".1.3.6.1.4.1.9.2.1.3.0";
my $oid_version       = ".1.3.6.1.2.1.1.1.0";
my $comm_rw           = "34antoN26sOi91SOiGA";
my $comm_ro           = "600meC73nerOK";
my $snmp_version      = "1";
my $sset              = "/usr/bin/snmpset";
my $sget              = "/usr/bin/snmpget";

my $host = "";
my $host2 = "";

my $message = "";
my $resultstring = "";

my $ios_type = "";

my $a = "";
my $c = "";

my $group = "";
my $type = "cisco";

my $ssh_bin = "/usr/bin/ssh -v -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no";
my $ssh_login = "cvs";
my $ssh_pass = "!Password123";


#=== decide if we are development or production ==============================

if(abs_path($0) =~ /\/dev/) {
  $dev = 1;
}
$prefix = sprintf($prefix, $dev ? 'dev' : 'prod');


#=== opening the logfile =====================================================

open LOG, "tail -f -c 0 $cisco_logfile|";


#=== eternal loop ============================================================

# this makes no sense, since quitting out of the inner loop won't cause
# logfile reopening

while(1) {


#=== logfile reading loop ====================================================

  while (<LOG>) {


#--- this regex triggers the processing, anything else is ignored
#--- the message being intercepted looks like the example below:

# Jun  5 10:12:10 stos20.oskarmobil.cz 1030270: Jun  5 08:12:10.109: \
# %SYS-5-CONFIG_I: Configured from console by rborelupo on vty0 \
# (172.20.113.120)

    /^(.+?) +(\d+) +([\d:]+) (.+?) .*SYS.*-CONFIG_I.*:(.*)$/ && do {
    
      $host = $4;
      $message = "$1 $2 $3 $5"; 

      print qq{Host: "$host"\n};
      print qq{Message: "$message"\n};

      print qq{Running command: "$sget -v $snmp_version $host -c $comm_ro $mib_hostname"\n};

      open(F,qq{$sget -v $snmp_version $host -c $comm_ro $mib_hostname |});
      $resultstring = <F>;
      close(F);

      if ($resultstring) {
        print qq{Resultstring: "$resultstring"\n};
        ($a, $host2, $c) = split('"',$resultstring);
        print qq{Real hostname: "$host2"\n};
      } else {
        print "Can't get hostname from snmp!\n";
        print "Parsing hostname from FQDN: $host.\n";
        $host2 = $host;
        $host2 =~ s/\..*//;
        print "Real hostname: \"$host2\"\n";
      }
	
      print "Checking IOS version...\n";
      print qq{Running command: "$sget -v $snmp_version $host -c $comm_ro $oid_version"\n};
      open(F,"$sget -v $snmp_version $host -c $comm_ro $oid_version |");
      $resultstring = <F>;
      close(F);

      # IOS XR is handled by connecting over SSH
      # apparently, this is merely done because TFTP doesn't
      # properly handle mgmt interface in an VRF

      if ($resultstring =~ m/Cisco IOS XR Software/) {
        print 'IOS: Cisco IOS XR Software';
        $ios_type = 'xr';
        $ssh_login = 'cvs1';
        $ssh_pass =  'yJhNSX4MbV';

        my $ssh_cmd = "backup-config";
        print "SSH Command: $ssh_cmd\n";
        my $cmd = "$ssh_bin -l $ssh_login $host";

        print "Running shell command: $cmd\n";
        my $ssh = Expect->spawn("$cmd");
        $ssh->log_stdout(0);

        if($ssh->expect(undef, "password:")) {
          print "Inserting password...\n";
          print $ssh "$ssh_pass\r";
        }
  
        if($ssh->expect(undef,'-re', '^RP/.*/RSP.*/CPU.*:.*NB00#$')) {
          print "Running remote ssh command...\n";
          print $ssh "$ssh_cmd\r";
         sleep 1;
        }

        if($ssh->expect(undef,'-re', "control-c to abort")) {
          print "Confirmation...\n";
          print $ssh "\n";
          sleep 1;
        }
  
        if($ssh->expect(undef,'-re', "control-c to abort")) {
          print "Confirmation...\n";
          print $ssh "\n";
	  sleep 1;
        }
  
        if($ssh->expect(undef,'-re', '^RP/.*/RSP.*/CPU.*:.*NB00#$')) {
          print "Logging out...\n";
          print $ssh "exit\n";
        }

        sleep 2;

      } 
    
      # normal IOS
    
      else {
        print "IOS: Normal\n";
        $ios_type = "normal";
      }

      # assign admin group

      if(
        $host2 =~ m/^(bsc|rnc|bud|sitR|sitS|gtsR|bce|sitnb|strnb).+$/
        || $host2 =~ m/^rcnR0(4|5)m$/
        || $host2 =~ m/^.*(C2811OB).*$/
        || $host2 =~ m/^vinR00i$/
      ) {
        $group = "nsu";
      } elsif(
        $host2 =~ m/^(vinPE02|sitPE0[23].*|A[123456]|CA|DCN|.*INFSERV.*)$/
      ) {
        $group = "infserv";
      } else {
        $group = "netit";
      }

      my $exec = sprintf(
        '%s/bin/cvs_new_version.sh %s %s "%s" %s %s %s',
        $prefix, $host, $host2, $message, $type, $group, $ios_type
      );
      print "Running CVS script...\n";
      print $exec, "\n";
      #system($exec);
      print "Done...\n";
    }
    
  }

}


