#!/usr/bin/perl -w
#
# (c) 2009 Alexander Leonov
#

#use Net::SSH::Perl;
use Expect;
use strict;
#use Net::SSH2;

my $logfile = "/var/log/network/ims.log";

my $repository = "/opt/cvs/prod/data/ims";
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

my $group = "ims";
my $type = "extreme";


open LOG, "tail -1cf $logfile|";

while (1) {

while (<LOG>) {
/^(.*)\s(.+)(\.oskarmobil\.cz).*cli:(.*)\(.*\)\s(.*)(:\ssave\sconfiguratio)n$/ && do {

    $username = $6;
	$host = $2;
    $message = "$1 $host$3 $4 $5 $6 $7";
	print "Matched message: $message\n";
	print "Matched username: $username\n";
	print "Matched hostname: $host\n";
	
	print "Waiting 10sec...";
	sleep 10;
	print "done\n";

	if($username !~ /^(cvs)/) {

		my $ssh_cmd = "show configuration";
		print "SSH Command: $ssh_cmd\n";
		my $cmd = "$ssh_bin -l $ssh_login $host";
	
		print "Running shell command: $cmd\n";
		my $ssh = Expect->spawn("$cmd");
		$ssh->log_stdout(0);

		if ($ssh->expect(undef, "Enter password for cvs: ")) {
			print "Inserting password...";
			print $ssh "$ssh_pass\r";
			print "done\n";
		}

		if ($ssh->expect(undef, " #")) {
			print "Running remote ssh command...";
			print $ssh "disable clipaging\r";
			print "done\n";
		}

		if ($ssh->expect(undef, " #")) {
			print "Running remote ssh command...";
			$ssh->log_file("$tftpdir/$host", "w");
			print $ssh "$ssh_cmd\r";
			print "done\n";
		}	

		if ($ssh->expect(undef, " #")) {
			print "Logging out...\n";
			print $ssh "exit\n";
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
