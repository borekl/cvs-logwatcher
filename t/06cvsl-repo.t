#/usr/bin/perl

use strict;
use warnings;
use Test2::V0;
use Path::Tiny;
use FindBin qw($Bin);

use CVSLogwatcher::Config;
use CVSLogwatcher::Repo;
use CVSLogwatcher::File;

my $cfg = CVSLogwatcher::Config->instance(
  basedir => path("$Bin")->parent,
  config_file => path("$Bin")->parent->child('cfg')->child('config.cfg')
);

#--- GENERIC TESTS -------------------------------------------------------------

{ # test the subsume method
  my $r = CVSLogwatcher::Repo::RCS->new(base => '/aaa/bbb/ccc');
  ok($r->subsumes('/aaa/bbb/ccc/ddd'), 'Method subsumes 1');
  ok(!$r->subsumes('/aaa/eee/ccc/ddd'), 'Method subsumes 2');
  # test the get_relative method
  my $p = path('/aaa/bbb/ccc/ddd');
  is($r->get_relative($p), 'ddd', 'Method get_relative 1');
  $p = path('xxx/yyy/zzz');
  is($r->get_relative($p), 'xxx/yyy/zzz', 'Method get_relative 2');
  $p = path('/aaa/fff/ccc/ddd');
  ok(dies { $r->get_relative($p) }, 'Method get_relative 3');
}

#--- RCS TESTS -----------------------------------------------------------------

{ # RCS/is_repo_file
  my $tempdir = Path::Tiny->tempdir;
  my $subdir = $tempdir->child('testdir')->mkdir;
  my $tempfile = $subdir->tempfile;
  my $tempfile_rcs = $tempfile->sibling($tempfile->basename . ',v')->touch;
  my $tempfile_not = $tempfile->sibling('x1');
  my $r = CVSLogwatcher::Repo::RCS->new(base => $tempdir);
  # unsuffixed RCS file returns true
  ok($r->is_repo_file($tempfile, 'testdir'), 'RCS: is_repo_file 1');
  # suffixed RCS file returns true
  ok($r->is_repo_file($tempfile_rcs, 'testdir'), 'RCS: is_repo_file 2');
  # non-existent file returns false
  ok(!$r->is_repo_file($tempfile_not, 'testdir'), 'RCS: is_repo_file 3');
  # file without path is fine
  ok($r->is_repo_file($tempfile->basename, 'testdir'), 'RCS: is_repo_file 4');
  # file's path is ignored, only basename matters
  ok($r->is_repo_file(path('/something', $tempfile->basename), 'testdir'), 'RCS: is_repo_file 5');
}

{
  # RCS/commit_file/checkout_file
  my $tempdir = Path::Tiny->tempdir;
  my $tempfile = $tempdir->child('TestFile');
  my $targetdir = $tempdir->child('targetdir')->mkdir;
  $tempfile->spew(join("\n", (1..10)));
  my $file = CVSLogwatcher::File->new(file => $tempfile);
  my $r = CVSLogwatcher::Repo::RCS->new(base => $tempdir);
  my $file_out;
  ok(lives {
    $r->commit_file($file, 'targetdir',
    who => 'test', msg => 'test', host => 'test'
  )}, 'RCS: commit_file (1)');
  ok($targetdir->child('TestFile,v')->is_file, 'RCS: commit_file (2)');
  ok(lives {
    $file_out = $r->checkout_file($tempfile, 'targetdir')},
    'RCS: checkout_file (1)'
  );
  ok($file_out, 'RCS: checkout_file (2)' );
  isa_ok($file_out, ['CVSLogwatcher::File'], 'RCS: checkout_file (3)' );
  is(scalar(@{$file_out->content}), 10, 'RCS: checkout_file (4)');
  ok(!$file->is_changed($file_out), 'RCS: checkout_file (5)');
}

#--- GIT TESTS -----------------------------------------------------------------

my ($tempdir, $git);
{ # git: initialization of a repository
  $tempdir = Path::Tiny->tempdir;
  ok(lives {
    $git = CVSLogwatcher::Repo::Git->new(type => 'Git', base => $tempdir);
    $git->git;
  }, 'Initializing git repository succeeds');
  ok(-d $tempdir->child('.git'), 'Git repo creation check (.git subdir)');
  ok($git->git->is_empty, 'Git repo creation check (is_empty)');
}

# create test git file (the tempdir is turned into a git repository)
my $temp_git = $tempdir->tempfile;
$temp_git->spew(join("\n", (1..10)));
my $index = $git->git->index;
$index->add($temp_git->basename);
$index->write;
my $tree_id = $index->write_tree;
my $tree = $git->git->lookup($tree_id);
my $me = Git::Raw::Signature->now('Test', 'test@email');
my $commit = $git->git->commit('Test commit', $me, $me, [], $tree);

{ # git: test is_repo_file
  my $non_git_file = $tempdir->tempfile;
  my $nonexist_file = $tempdir->child('i_am_not');
  $non_git_file->spew(join("\n", (1..10)));
  ok($git->is_repo_file($temp_git), 'git: is_repo_file 1');
  ok(!$git->is_repo_file($non_git_file), 'git: is_repo_file 2');
  ok(!$git->is_repo_file($nonexist_file), 'git: is_repo_file 3');
}

my $tempfile_name;
my $file;

{ # git: commit_file
  my $tempfile = Path::Tiny->tempfile;
  $tempfile_name = $tempfile->basename;
  $tempfile->spew(join("\n", (11..20)));
  $tempdir->child('targetdir')->mkdir;
  $file = CVSLogwatcher::File->new(file => $tempfile);
  my $git = CVSLogwatcher::Repo::Git->new(base => $tempdir);
  # commit_file(1): did not throw exception
  ok(lives { $git->commit_file($file, 'targetdir') }, 'git: commit_file (1)');
  # commit_file(2): the file exists in repository directory
  ok($tempdir->child('targetdir', $tempfile->basename)->exists, 'git: commit_file (2)');
}

{ # git: checkout_file
  my $git = CVSLogwatcher::Repo::Git->new(base => $tempdir);
  my $f;
  ok(lives {
    $f = $git->checkout_file($tempfile_name, 'targetdir')
  }, 'git: checkout_file (1)');
  isa_ok($f, ['CVSLogwatcher::File'], 'git: checkout file (2)');
  ok(!$file->is_changed($f), 'git: checkout file (3)');
}

done_testing;
