#!/usr/bin/perl -w
#
# (c) 2000 Expert & Partner engineering
#

use Expect;
use strict;

my $cisco_logfile = "/var/log/cisco_all.log";
my $logfile = "/var/log/cvs_cisco.log";
my $myip = "172.20.113.120";
my $myip_new_external = "217.77.161.62";
my $mib_config = ".1.3.6.1.4.1.9.2.1.55";
my $mib_hostname = ".1.3.6.1.4.1.9.2.1.3.0";
my $oid_version = ".1.3.6.1.2.1.1.1.0";
#my $comm_rw = "07antoN69sOi71SOiGA";
my $comm_rw = "34antoN26sOi91SOiGA";
my $comm_ro = "600meC73nerOK";
my $snmp_version = "1";
my $tftp = "/tftpboot";
my $repository = "/opt/cvs/routers";
my $home = "/opt/bin";
my $sset = "/usr/bin/snmpset";
my $sget = "/usr/bin/snmpget";
my $rcs = "/usr/bin/rcs";
my $ci = "/usr/bin/ci";

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

open LOG, "tail -f -c 0 $cisco_logfile|";

while (1) {

while (<LOG>) {
	/^(.+?) +(\d+) +([\d:]+) (.+?) .*SYS.*-CONFIG_I.*:(.*)$/ && do {
    

	$host = $4;
	$message = "$1 $2 $3 $5"; 

	print "Host: \"$host\"\n";
	print "Message: \"$message\"\n";


	print "Running command: \"$sget -v $snmp_version $host -c $comm_ro $mib_hostname\"\n";

	open(F,"$sget -v $snmp_version $host -c $comm_ro $mib_hostname |");
		$resultstring = <F>;
	close(F);

	if ($resultstring) {
		print "Resultstring: \"$resultstring\"\n";
		($a, $host2, $c) = split('"',$resultstring);
		print "Real hostname: \"$host2\"\n";
	} else {
		print "Cant get hostname from snmp!\n";
		print "Parsing hostname from FQDN: $host.\n";
		$host2 = $host;
		$host2 =~ s/\..*//;
		#($host2, $a, $c) = split('.',$host);
		print "Real hostname: \"$host2\"\n";
	}

	
	print "Checking IOS version...\n";
	print "Running command: \"$sget -v $snmp_version $host -c $comm_ro $oid_version\"\n";
        open(F,"$sget -v $snmp_version $host -c $comm_ro $oid_version |");
                $resultstring = <F>;
        close(F);

	if ($resultstring =~ m/^.*Cisco IOS XR Software.*$/) {
		#print "Resultstring: \"$resultstring\"\n";
		print "IOS: Cisco IOS XR Software";
		$ios_type = "xr";
		$ssh_login = 'cvs1';
		$ssh_pass =  'yJhNSX4MbV';

		my $ssh_cmd = "backup-config";
                print "SSH Command: $ssh_cmd\n";
                my $cmd = "$ssh_bin -l $ssh_login $host";

                print "Running shell command: $cmd\n";
                my $ssh = Expect->spawn("$cmd");
                $ssh->log_stdout(0);

                if ($ssh->expect(undef, "password:")) {
                        print "Inserting password...\n";
                        print $ssh "$ssh_pass\r";
                }

                if ($ssh->expect(undef,'-re', '^RP/.*/RSP.*/CPU.*:.*NB00#$')) {
                        print "Running remote ssh command...\n";
                        #$ssh->log_file("$tftpdir/$host", "w");dd
                        #open OUTPUT, '>', "$tftpdir/$host" or die "Can't create filehandle: $!";
                        #print OUTPUT $ssh "$ssh_cmd\r";
                        print $ssh "$ssh_cmd\r";
                        #close(OUTPUT);
			sleep 1;
                }

		if ($ssh->expect(undef,'-re', "control-c to abort")) {
                        print "Confirmation...\n";
                        print $ssh "\n";
			sleep 1;
                }

		if ($ssh->expect(undef,'-re', "control-c to abort")) {
                        print "Confirmation...\n";
                        print $ssh "\n";
			sleep 1;
                }

                if ($ssh->expect(undef,'-re', '^RP/.*/RSP.*/CPU.*:.*NB00#$')) {
                        print "Logging out...\n";
                        print $ssh "exit\n";
                }

                sleep 2;

	} else {
		print "IOS: Normal\n";
		$ios_type = "normal";
	}


	#next if $host2;

	#if($host =~ /^(isp|gts|sitr00i)/i) {
	#	print "External host: \"$host2\"";
	#	print "Running command: \"$sset -t 20 -r 2 -c $comm_rw $host $mib_config.$myip_new_external s cs/$host2\"\n";

	#	next if system("$sset -t 20 -r 2 -c $comm_rw $host $mib_config.$myip_new_external s cs/$host2");

	#} else {
#		print "Normal host: \"$host2\"\n";
#		sleep 15;
#		print "Running command: \"$sset -t 200 -c $comm_rw  $host $mib_config.$myip s cs/$host2\"\n";
		
#      	next if system("$sset -t 200 -c $comm_rw  $host $mib_config.$myip s cs/$host2");
	#}

	if (($host2 =~ m/^(bsc|rnc|bud|sitR|sitS|gtsR|bce|sitnb|strnb).+$/) || ($host2 =~ m/^rcnR0(4|5)m$/) || ($host2 =~ m/^.*(C2811OB).*$/) || ($host2 =~ m/^vinR00i$/)) {
		$group = "nsu";
	} elsif ($host2 =~ m/^(vinPE02|sitPE0[23].*|A[123456]|CA|DCN|.*INFSERV.*)$/) {
		$group = "infserv";
	} else {
		$group = "netit";
	}

	print "Running CVS script...\n";
	print "/bin/bash /opt/cvs/prod/bin/cvs_new_version.sh $host $host2 \"$message\" $type $group $ios_type";
	system("/bin/bash /opt/cvs/prod/bin/cvs_new_version.sh $host $host2 \"$message\" $type $group $ios_type");

#	do {
#		open RCS, "|$rcs -i -U $repository/$host2,v";
#		print RCS "$host2 configuration"; close RCS;
#	} if !-f "$repository/$host2,v";
#		open RCS, "|$ci $tftp/cs/$host2 $repository/$host2,v"; 
#		print RCS "$message\n"; close RCS;
#
#	print "Setting permission 0666 to CVS file...\n";
#	system("/bin/chmod 666 $repository/$host2,v");

	print "Done...\n"
	} #REGEXP
} #WHILE

} #1


