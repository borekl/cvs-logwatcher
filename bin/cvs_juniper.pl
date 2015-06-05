#!/usr/bin/perl -w
#
# (c) 2009 Alexander Leonov
#

#use Net::SSH::Perl;
use Expect;
use strict;
#use Net::SSH2;

my $logfile = "/var/log/network/fw.log";

my $repository = "/opt/cvs/prod/data/secit";
my $tftpdir = "/tftpboot/cs";
#$sset = "/usr/local/bin/snmpset";
#$sget = "/usr/local/bin/snmpget";
my $rcs = "/usr/bin/rcs";
my $ci = "/usr/bin/ci";
my $host = "";
my $username = "";
my $message = "";
my $ssh_bin = "/usr/bin/ssh -v -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no";
my $ssh_login = "tufin";
my $ssh_pass = "hag92qku";

my $group = "secit";
my $type = "juniper";


open LOG, "tail -1cf $logfile|";

while (1) {

while (<LOG>) {
/^(.*)\s(.+)(\.oskarmobil\.cz)\s(.*)(UI_COMMIT_PROGRESS: Commit operation in progress: commit complete)$/ && do {

#Nov 20 14:46:00 strnfw99.oskarmobil.cz mgd[92856]: UI_COMMIT_PROGRESS: Commit operation in progress: commit complete

#Nov 20 13:45:18 10.21.148.68 mgd[92736]: UI_COMMIT: User 'root' requested 'commit' operation (comment: none)
#|Nov 20 12:46:59| |vinpe00| |.oskarmobil.cz| |TMNX: 6338 Base | |USER-MINOR-cli_user_logout|-2002 [account_stat]:  User from 172.20.242.232 logged out

#    $username = $7;
	$host = $2;
    $message = "$1 $host$3 $4 $5";
	print "Matched message: $message\n";
#	print "Matched username: $username\n";
	print "Matched hostname: $host\n";

#	if($username !~ /^()/) {

		#my $ssh_cmd = "admin save tftp://172.20.113.120/cs/$host";
		my $ssh_cmd = "show configuration | display set | no-more";
		print "SSH Command: $ssh_cmd\n";
		my $cmd = "$ssh_bin -l $ssh_login $host";
	
		print "Running shell command: $cmd\n";
		my $ssh = Expect->spawn("$cmd");
		$ssh->log_stdout(0);

		if ($ssh->expect(undef, "password:")) {
			print "Inserting password...\n";
			print $ssh "$ssh_pass\r";
		}

		if ($ssh->expect(undef,'-re', '^tufin@.*> $')) {
			print "Running remote ssh command...\n";
			$ssh->log_file("$tftpdir/$host", "w");
			#open OUTPUT, '>', "$tftpdir/$host" or die "Can't create filehandle: $!";
			#print OUTPUT $ssh "$ssh_cmd\r";
			print $ssh "$ssh_cmd\r";
			#close(OUTPUT);
		}	

		if ($ssh->expect(undef,'-re', '^tufin@.*> $')) {
			print "Logging out...\n";
			print $ssh "exit\n";
		}

		sleep 2;

    print "Running CVS script...\n";
    system("/bin/bash /opt/cvs/prod/bin/cvs_new_version.sh $host $host \"$message\" $type $group");


#	} else { #IF
#		print "Skipping for username $username...\n"
#	}

$host = "";
#$username = "";
$message = "";

} #DO
}

} #WHILE 1
