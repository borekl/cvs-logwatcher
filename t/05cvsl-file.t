#/usr/bin/perl

use strict;
use warnings;
use Test2::V0;
use Path::Tiny;
use FindBin qw($Bin);
use Git::Raw;

use CVSLogwatcher::Config;
use CVSLogwatcher::File;

my $cfg = CVSLogwatcher::Config->instance(
  basedir => path("$Bin")->parent,
  config_file => path("$Bin")->parent->child('cfg')->child('config.cfg')
);

# create temporary testing repository directory
my $repodir = Path::Tiny->tempdir;
$cfg->repodir('rcs', $repodir);
$cfg->repodir('git', $repodir);

# create test plain file
my $temp_plain = $repodir->tempfile;
$temp_plain->spew(join("\n", (1..10)));

# create test RCS file
my $temp_rcs = $repodir->tempfile;
$temp_rcs->spew(join("\n", (1..10)));
system('ci -q -t- ' . $temp_rcs->stringify);
my $rcs_file = path($temp_rcs->stringify . ',v');
system('rcs -q -U ' . $rcs_file->stringify);

# create test git file (the tempdir is turned into a git repository)
my $temp_git = $repodir->tempfile;
my $git = Git::Raw::Repository->init($repodir, 0);
$temp_git->spew(join("\n", (1..10)));
my $index = $git->index;
$index->add($temp_git->basename);
$index->write;
my $tree_id = $index->write_tree;
my $tree = $git->lookup($tree_id);
my $me = Git::Raw::Signature->now('Test', 'test@email');
my $commit = $git->commit('Test commit', $me, $me, [], $tree);


{ # creation of an instance from plain file
  my $file = CVSLogwatcher::File->new(file => $temp_plain);
  isa_ok($file, 'CVSLogwatcher::File');
  is($file->count, 10, 'Count on plain file');
  ok($file->size > 0, 'Size on plain file');
  ok(!$file->is_rcs_file, 'Plain file is not RCS file');
  ok(!$file->is_git_file, 'Plain file is not git file');
  $file->remove;
  ok(!-f $temp_plain, 'File was removed successfully');
}

{ # creation of an instance from RCS file
  my $file = CVSLogwatcher::File->new(file => $rcs_file);
  isa_ok($file, 'CVSLogwatcher::File');
  is($file->count, 10, 'Count on plain file');
  ok($file->size > 0, 'Size on plain file');
  ok($file->is_rcs_file, 'RCS file is RCS file');
  ok(!$file->is_git_file, 'RCS file is not git file');
}

{ # creation of an instance from git file
  my $file = CVSLogwatcher::File->new(file => $temp_git);
  isa_ok($file, 'CVSLogwatcher::File');
  is($file->count, 10, 'Count on plain file');
  ok($file->size > 0, 'Size on plain file');
  ok(!$file->is_rcs_file, 'RCS file is not git file');
  ok($file->is_git_file, 'git file is git file');
}

done_testing();
