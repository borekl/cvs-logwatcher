#!/usr/bin/perl

use strict;
use warnings;
use Test2::V0;

use CVSLogwatcher::Cmdline;

# instance creation
isa_ok(my $cmd = CVSLogwatcher::Cmdline->new);

# default values are as expected
is($cmd, object {
  call trigger    => U();
  call host       => U();
  call user       => U();
  call msg        => U();
  call force      => F();
  call nochecking => U();
  call mangle     => T();
  call initonly   => F();
  call log        => U();
  call watchonly  => F();
  call debug      => F();
  call devel      => F();
  call task       => U();
}, 'Default values');

# binary options work
$cmd = CVSLogwatcher::Cmdline->new(cmdline => join(' ',
  '--force', '--debug', '--devel', '--initonly',
  '--nocheckin', '--watchonly --nomangle'
));
is($cmd, object {
  call force     => T();
  call nocheckin => D();
  call mangle    => F();
  call initonly  => T();
  call watchonly => T();
  call debug     => T();
  call devel     => T();
}, 'Binary options');

# options with string values work
$cmd = CVSLogwatcher::Cmdline->new(cmdline => join(' ',
  '--trigger=MyTriggerValue',
  '--host=MyHostValue',
  '--user=MyUserValue',
  '--msg=MyMsgValue',
  '--nocheckin=NoCheckInValue',
  '--task=MyTaskValue'
));
is($cmd, object {
  call trigger   => 'mytriggervalue';
  call host      => 'myhostvalue';
  call user      => 'MyUserValue';
  call msg       => 'MyMsgValue';
  call nocheckin => 'NoCheckInValue';
  call task      => 'MyTaskValue';
}, 'String options');

# --devel enables --debug
$cmd = CVSLogwatcher::Cmdline->new(cmdline => '--devel');
ok($cmd->debug, '-devel enables --debug');

# finish
done_testing();
