#!/usr/bin/perl -w
#
# (c) 2009 Alexander Leonov
#

#use Net::SSH::Perl;
use Expect;
use strict;
#use Net::SSH2;

my $logfile = "/var/log/cpn_change.log";

my $repository = "/opt/cvs/prod/data/nsu";
my $tftpdir = "/tftpboot/cs";
#$sset = "/usr/local/bin/snmpset";
#$sget = "/usr/local/bin/snmpget";
my $rcs = "/usr/bin/rcs";
my $ci = "/usr/bin/ci";
my $host = "";
my $username = "";
my $message = "";
my $ssh_bin = "/usr/bin/ssh -v -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no";
my $ssh_login = "cvs";
my $ssh_pass = "!Password123";

my $group = "nsu";
my $type = "cpn";


open LOG, "tail -1cf $logfile|";

while (1) {

while (<LOG>) {
/^(.*)\s(.+)(\.oskarmobil\.cz)\s(.*)(USER-MINOR-cli_user_logout)(.*)\s\[(\w+)\](.*)$/ && do {
    $username = $7;
	$host = $2;
    $message = "$1 $host$3 $4 $5$6 [$username] $8";
	print "Matched message: $message\n";
	print "Matched username: $username\n";
	print "Matched hostname: $host\n";

	if($username !~ /^(cvs|alu-stats|account_stat)/) {

		my $ssh_cmd1 = "admin save tftp://172.20.113.120/cs/$host";
		my $ssh_cmd2 = "admin save";
		print "SSH Command: $ssh_cmd1\n";
		my $cmd = "$ssh_bin -l $ssh_login $host";
	
		print "Running shell command: $cmd\n";
		my $ssh = Expect->spawn("$cmd");
		$ssh->log_stdout(0);

		if ($ssh->expect(undef, "password:")) {
			print "Inserting password...\n";
			print $ssh "$ssh_pass\r";
		}

		if ($ssh->expect(undef, "#")) {
			print "Running remote ssh command...\n";
			print $ssh "$ssh_cmd1\r";
		}

		if ($ssh->expect(undef, "#")) {
                        print "Running remote ssh command...\n";
                        print $ssh "$ssh_cmd2\r";
                }
	

		if ($ssh->expect(undef, "#")) {
			print "Logging out...\n";
			print $ssh "logout\n";
		}

		sleep 2;

    print "Running CVS script...\n";
    system("/bin/bash /opt/cvs/prod/bin/cvs_new_version.sh $host $host \"$message\" $type $group");


	} else { #IF
		print "Skipping for username $username...\n"
	}

$host = "";
$username = "";
$message = "";

} #DO
}

} #WHILE 1
