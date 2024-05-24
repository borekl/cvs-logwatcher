#/usr/bin/perl

use strict;
use warnings;
use experimental 'postderef';
use Path::Tiny qw(cwd);
use Test2::V0;

use CVSLogwatcher::Config;

# temporary configuration file
my $tempdir = Path::Tiny->tempdir;
my $config_file = $tempdir->child('config.cfg');
$config_file->spew_utf8('{}');

# configuration example
my $cfg_example = cwd->child('cfg/config.cfg.example');
ok($cfg_example->is_file, 'Example configuration file exists');

{
  # instance creation
  isa_ok(my $cfg = CVSLogwatcher::Config->new(
    basedir => cwd, config_file => $config_file
  ), 'CVSLogwatcher::Config');

  # tempdir non-existent dir
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
}

{
  # tempdir existing dir
  $config_file->spew_utf8(qq[{ config => { tempdir => "$tempdir" }}]);
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

{
  my $cfg;

  # successfully read example configuration
  ok(lives { $cfg = CVSLogwatcher::Config->new(
    basedir => cwd,
    config_file => $cfg_example
  )}, 'Read example config');

  # verify logger instance
  isa_ok($cfg->logger, 'Log::Log4perl::Logger');

  # keyring
  ok($cfg->keyring, hash {
    field '%1' => 'SomePassword1';
    field '%2' => 'SomePassword2';
    field '%3' => 'An0therPa$$word3';
    field '%4' => 'Y3tAn07herPa$$4';
    field '%5' => '3v3nMorePwds5';
    end();
  }, 'Keyring configuration');

  # config.logprefix
  is($cfg->logprefix, '/var/log', "Config key 'config.logprefix'");

  # config.rcs
  is($cfg->config->{rcs}, hash {
    field 'rcsrepo' => 'data';
    field 'rcsctl' => '/usr/bin/rcs';
    field 'rcsci' => '/usr/bin/ci';
    field 'rcsco' => '/usr/bin/co';
    end();
  }, "Config key 'config.rcs'");

  # config.logfiles
  is($cfg->logfiles, hash {
    field 'cisco' => object {
      prop blessed => 'CVSLogwatcher::Logfile';
      call id => 'cisco';
      call file => '/var/log/cisco/cisco.log';
      call matchre => T();
      end();
    };
    field 'alu' => object {
      prop blessed => 'CVSLogwatcher::Logfile';
      call id => 'alu';
      call file => '/var/log/network/cpn/change.log';
      call matchre => T();
      end();
    };
    field 'juniper' => object {
      prop blessed => 'CVSLogwatcher::Logfile';
      call id => 'juniper';
      call file => '/var/log/network/fw.log';
      call matchre => T();
      end();
    };
    end();
  }, 'Logfiles configuration');

  # config.targets, all items are Target instances
  is($cfg->targets, array {
    item object { prop blessed => 'CVSLogwatcher::Target' }
    foreach (1 .. $cfg->targets->@*);
  });

  # config.targets, getting target by id, check what's returned
  my $t = $cfg->get_target('cisco-ssh');
  is($t, object {
    prop blessed => 'CVSLogwatcher::Target';
    call 'id' => 'cisco-ssh';
    call 'defgroup' => 'netit';
    call 'filter' => array { item $_ => T() foreach (0..2) };
    call 'validate' => array { item 0 => T(); end; };
    call 'expect' => object {
      prop blessed => 'CVSLogwatcher::Expect';
    };
  }, 'Target instance');
}

# finish
done_testing();
