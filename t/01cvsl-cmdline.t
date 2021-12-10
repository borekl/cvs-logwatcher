#!/usr/bin/perl

use strict;
use warnings;
use Test::More;

use CVSLogwatcher::Cmdline;

my $cmd = CVSLogwatcher::Cmdline->new;

# creation of an instance works

ok(
  defined $cmd && ref $cmd && $cmd->isa('CVSLogwatcher::Cmdline'),
  'instance creation'
);

# default values are as expected

ok(
  !defined $cmd->trigger
  && !defined $cmd->host
  && !defined $cmd->user
  && !defined $cmd->msg
  && !$cmd->force
  && !defined $cmd->nocheckin
  && $cmd->mangle
  && !$cmd->initonly
  && !defined $cmd->log
  && !$cmd->watchonly
  && !$cmd->debug
  && !$cmd->devel
  && !defined $cmd->task,
  'defaults'
);

# binary options work

$cmd = CVSLogwatcher::Cmdline->new(
  cmdline => join(' ',
    '--force', '--debug', '--devel', '--initonly',
    '--nocheckin', '--watchonly --nomangle'
  )
);

ok(
  $cmd->force
  && defined $cmd->nocheckin
  && !$cmd->mangle
  && $cmd->initonly
  && $cmd->watchonly
  && $cmd->debug
  && $cmd->devel,
  'binary options'
);

# options with string values work

$cmd = CVSLogwatcher::Cmdline->new(
  cmdline => join(' ',
    '--trigger=MyTriggerValue',
    '--host=MyHostValue',
    '--user=MyUserValue',
    '--msg=MyMsgValue',
    '--nocheckin=NoCheckInValue',
    '--task=MyTaskValue'
  )
);

is($cmd->trigger, 'mytriggervalue',   '--trigger value');
is($cmd->host, 'myhostvalue',         '--host value');
is($cmd->user, 'MyUserValue',         '--user value');
is($cmd->msg, 'MyMsgValue',           '--msg value');
is($cmd->nocheckin, 'NoCheckInValue', '--nocheckin value');
is($cmd->task, 'MyTaskValue',         '--task value');

# --devel enables --debug

$cmd = CVSLogwatcher::Cmdline->new(cmdline => '--devel');
ok($cmd->debug, '-devel enables --debug');

# finish

done_testing();
