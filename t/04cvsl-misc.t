#/usr/bin/perl

use v5.36;
use Test2::V0;

use CVSLogwatcher::Misc qw(host_strip_domain);

# host_strip_domain()
is(host_strip_domain('aaa.bbb.ccc'), 'aaa', 'host domain stripping (1)');
is(host_strip_domain('172.20.30.40'), '172-20-30-40', 'host domain stripping (2)');

# finish
done_testing();
