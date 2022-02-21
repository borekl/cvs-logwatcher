#/usr/bin/perl

use strict;
use warnings;
use Path::Tiny qw(cwd);
use Test2::V0;

use CVSLogwatcher::Config;

my $tempdir = Path::Tiny->tempdir;
my $config_file = $tempdir->child('config.json');
$config_file->spew_utf8('{}');

{
  # instance creation
  isa_ok(my $cfg = CVSLogwatcher::Config->new(
    basedir => cwd, config_file => $config_file
  ), 'CVSLogwatcher::Config');

  # tempdir non-existent dir
  $config_file->spew_utf8(qq[{ "config":{"tempdir": "${tempdir}_$$" }}]);
  $cfg = CVSLogwatcher::Config->new(
    basedir => $tempdir,
    config_file => $config_file
  );
  like(
    dies { $cfg->tempdir->stringify },
    qr/not found/,
    'Missing config.tempdir'
  );
}

{
  # tempdir existing dir
  $config_file->spew_utf8(qq[{ "config":{"tempdir": "$tempdir" }}]);
  my $cfg = CVSLogwatcher::Config->new(
    basedir => $tempdir, config_file => $config_file
  );
  is(
    $cfg->tempdir->stringify,
    $tempdir->stringify,
    'Existing config.tempdir'
  );

  # check 'repl' attribute contains properly initialized CVSLogwatcher::Repl
  # instance, including the %D token that shall contain the tempdir path
  isa_ok($cfg->repl, 'CVSLogwatcher::Repl');
  is($cfg->repl->replace('%D'), $tempdir->stringify, 'Temp dir in repl');
}

# finish
done_testing();
