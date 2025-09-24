#/usr/bin/perl

use v5.36;
use Path::Tiny qw(cwd);
use Test2::V0;

use CVSLogwatcher::Config;

# temporary configuration file
my $tempdir = Path::Tiny->tempdir;
my $config_file = $tempdir->child('config.cfg');

#------------------------------------------------------------------------------
# BASIC CHECKS
#------------------------------------------------------------------------------

# instance creation with minimal configuration succeeds
$config_file->spew_utf8('{}');
isa_ok(my $cfg = CVSLogwatcher::Config->new(
  basedir => cwd, config_file => $config_file
), 'CVSLogwatcher::Config');

# missing tempdir results in an exception
$config_file->spew_utf8(qq[{ config => { tempdir => "${tempdir}_$$" }}]);
$cfg = CVSLogwatcher::Config->new(
  basedir => $tempdir,
  config_file => $config_file
);
like(
  dies { $cfg->tempdir->stringify },
  qr/not found/,
  'Missing config.tempdir'
);

# existing tempdir is accepted
$config_file->spew_utf8(qq[{ config => { tempdir => "$tempdir" }}]);
$cfg = CVSLogwatcher::Config->new(
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

# default logprefix
is($cfg->logprefix->stringify, '/var/log', 'Logprefix default');

# check logprefix with absolute path
$config_file->spew_utf8(qq[{ config => { logprefix => '$tempdir' }}]);
$cfg = CVSLogwatcher::Config->new(
  basedir => $tempdir, config_file => $config_file
);
is($cfg->logprefix, $tempdir->stringify, 'Logprefix with absolute path');

#------------------------------------------------------------------------------
# LOGFILES
#------------------------------------------------------------------------------

$config_file->spew_utf8(<<"EOHD");
{
  logfiles => {
    abc => [ '/aaa/bbb/ccc' => 'mi1', 'mi2' ],
    def => [ 'eee' => 'mi3', 'mi4' ],
  }
}
EOHD

$cfg = CVSLogwatcher::Config->new(
  basedir => $tempdir, config_file => $config_file
);

# basic check, keys of the hash are ::Logfile instances
is($cfg->logfiles, hash {
  field 'abc' => check_isa('CVSLogwatcher::Logfile');
  field 'def' => check_isa('CVSLogwatcher::Logfile');
  end();
}, 'Logfiles (1)');

# check the instances of ::Logfile
is($cfg->logfiles, hash {
  field 'abc' => object {
    call id => 'abc';
    call file => check_isa('Path::Tiny');
    call file => object { call stringify => '/aaa/bbb/ccc'; };
    call matches => array { item 'mi1'; item 'mi2'; end(); };
  };
  field 'def' => object {
    call id => 'def';
    call file => check_isa('Path::Tiny');
    call file => object { call stringify => '/var/log/eee'; };
    call matches => array { item 'mi3'; item 'mi4'; end(); };
  };
});

# finish
done_testing();
