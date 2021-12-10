#/usr/bin/perl

use strict;
use warnings;
use Path::Tiny qw(cwd);
use CVSLogwatcher::Config;

use Test::More;
use Test::Fatal;

my $tempdir = Path::Tiny->tempdir;
my $config_file = $tempdir->child('config.json');
$config_file->spew_utf8('{}');

# creation of an instance works

my $cfg = CVSLogwatcher::Config->new(
  basedir => cwd, config_file => $config_file
);

ok(
  defined $cfg && ref $cfg && $cfg->isa('CVSLogwatcher::Config'),
  'instance creation'
);

# tempdir existing dir

$config_file->spew_utf8(qq[{ "config":{"tempdir": "$tempdir" }}]);

$cfg = CVSLogwatcher::Config->new(
  basedir => $tempdir, config_file => $config_file
);

is(
  $cfg->tempdir->stringify,
  $tempdir->stringify,
  'config.tempdir ex'
);

# tempdir non-existent dir

$config_file->spew_utf8(qq[{ "config":{"tempdir": "${tempdir}_$$" }}]);

$cfg = CVSLogwatcher::Config->new(
  basedir => $tempdir,
  config_file => $config_file
);

like(
  exception { $cfg->tempdir->stringify },
  qr/not found/,
  'config.tempdir non-ex'
);

done_testing();
