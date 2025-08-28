#/usr/bin/perl

use v5.36;
use Test2::V0;
use Path::Tiny;
use FindBin qw($Bin);

use CVSLogwatcher::Config;
use CVSLogwatcher::File;

my $cfg = CVSLogwatcher::Config->instance(
  basedir => path("$Bin")->parent,
  config_file => path("$Bin")->parent->child('cfg')->child('config.cfg')
);

{ # creation of an instance from explicit content with some basic tests
  my $file = CVSLogwatcher::File->new(file => 'some.file', content => []);
  isa_ok($file, ['CVSLogwatcher::File'], 'Instance from explicit content (1)');
  is($file->count, 0, 'Count on explicit content file (2)');
  is($file->size(1), 0, 'Size on explicit content file (3)');
  is($file->file, 'some.file', 'File name check (4)');
  ok(!$file->is_gzip_file, 'File is gzip (5)');
  $file->set_filename('other.file.gz');
  is($file->file, 'other.file.gz', 'File name check (6)');
  $file->set_path('/aaa/bbb');
  is($file->file, '/aaa/bbb/other.file.gz', 'File name check (7)');
  ok($file->is_gzip_file, 'File is gzip (8)');
  is($file->prev_size, 0, 'Prev_size attribute (9)');
  push($file->content->@*, 'abcd');
  is($file->size_change, -4, 'File size change on increase (10)');
  $file->size(1);
  is($file->size_change, 0, 'File size change on no change (11)');
  delete $file->content->[0];
  is($file->size_change, 4, 'File size change on decrease (12)');
  is($file->set_uc_filename, T(), 'File name uppercasing check (13)');
  is($file->file, '/aaa/bbb/OTHER.FILE.GZ', 'File name uppercasing check (14)');
  is($file->set_uc_filename, F(), 'File name uppercasing check (15)');
}

# create test plain file
my $tempdir = Path::Tiny->tempdir;
my $temp_plain = $tempdir->tempfile;
$temp_plain->spew(join("\n", (1..10)));

{ # creation of an instance from plain file
  my $file = CVSLogwatcher::File->new(file => $temp_plain);
  isa_ok($file, 'CVSLogwatcher::File');
  is($file->count, 10, 'Count on plain file');
  ok(!$file->is_gzip_file, 'Is gzip file on plain file');
  ok($file->size > 0, 'Size on plain file');
  $file->remove;
  ok(!-f $temp_plain, 'File was removed successfully');
}

{ # extract hostname
  my $file = CVSLogwatcher::File->new(
    file => 'some.file', content => [
      'NB/PrB2n5Ie9uDwOqJPqcG7PtH6mZf1m',
      'eQ6vKmcf1 hostname ABC123 ZuLqiC',
      'host(QWE678)t/bvzKP+QjH0KVGVvKse',
      'DQc8V01JKJ5xMZ5C8H7jcua85q0Xsb+X',
    ]
  );
  my $h = $file->extract_hostname(
    '\bhostname\s+(\S+)\b',
    '^host\((.*)\)',
  );
  is($h, 'ABC123', 'Extract hostname (1)');
  $h = $file->extract_hostname(
    '^host\((.*)\)',
    '\bhostname\s+(\S+)\b',
  );
  is($h, 'QWE678', 'Extract hostname (2)');
}

{ # normalize eol
  my $file = CVSLogwatcher::File->new(
    file => 'some.file', content => [
      "abcdef\x0d\x0a",
      "ghijkl\x0d",
      "mnopqr\n",
      "tuvwxy",
    ]
  );
  $file->normalize_eol;
  is($file->content->[0], "abcdef\n", 'Normalize EOL (1)');
  is($file->content->[1], "ghijkl\n", 'Normalize EOL (2)');
  is($file->content->[2], "mnopqr\n", 'Normalize EOL (3)');
  is($file->content->[3], "tuvwxy\n", 'Normalize EOL (4)');
}

{ # valid range
  my $content = [
    'w3p0fpNMgUXJPfpBvPet6',
    'vmXxQsALaR9BwZytutiJp',
    'begin lhC9Z+TrPkBtkrM',
    'L++qANUcwnb6tnrCPwv+D',
    'uDn/9DzkALRPPpMqtiCxK',
    'Y/oRhNUPU0LhqzRHcMemU',
    '8kaqALPxlC3dt5QSDBKkQ',
    'end PrB2n5Ie9uDwOqJPq',
    'fC71uHix+PKitHkYgnJfK',
  ];
  my $file = CVSLogwatcher::File->new(file => 'some.file', content => $content);
  $file->validrange('^begin\s', '^end\s');
  is($file->count, 6, 'Valid range (1)');
  is($file->content->[0], 'begin lhC9Z+TrPkBtkrM', 'Valid range (2)');
  is($file->content->[-1], 'end PrB2n5Ie9uDwOqJPq', 'Valid range (3)');

  $file = CVSLogwatcher::File->new(file => 'some.file', content => $content);
  $file->validrange(undef, '^end\s');
  is($file->count, 8, 'Valid range (4)');
  is($file->content->[0], 'w3p0fpNMgUXJPfpBvPet6', 'Valid range (5)');
  is($file->content->[-1], 'end PrB2n5Ie9uDwOqJPq', 'Valid range (6)');

  $file = CVSLogwatcher::File->new(file => 'some.file', content => $content);
  $file->validrange('^begin\s');
  is($file->count, 7, 'Valid range (6)');
  is($file->content->[0], 'begin lhC9Z+TrPkBtkrM', 'Valid range (7)');
  is($file->content->[-1], 'fC71uHix+PKitHkYgnJfK', 'Valid range (8)');
}

{ # filter
  my $content = [
    'ALRPPpMqtiCxKt7UM0NYC',
    'U0LhqzRHcMemURK7Qu+Mp',
    'lC3dt5QSDBKkQGteB5gQd',
    '+PKitHkYgnJfKv/rDxi+b',
    'n5Ie9uDwOqJPqcG7PtH6m',
    'f1GL38pWTroc5ZVspWtZu',
    'fC71uHix+PKitHkYgnJfK',
  ];
  my $file = CVSLogwatcher::File->new(file => 'some.file', content => $content);
  $file->filter('qtiC', 'RHc', '38p');
  is($file->count, 4, 'Filter (1)');
  is($file->content->[0], 'lC3dt5QSDBKkQGteB5gQd', 'Filter (2)');
  is($file->content->[-2], 'n5Ie9uDwOqJPqcG7PtH6m', 'Filter (3)');
}

{ # validate
  my $content = [
    'OG/aTsiK5jhpDwkXE1',
    'vUIQwminnie0XFFYvz',
    'FhZeuVy9chLWAhv5CH',
    'Q9SuzJuunKaWtw+BW7',
    'gJU1Ywinniewc7F09A',
    'G+tYTd2rZe3I4CYh7B',
    'e6vyMtLr4eyXcg/Dfc',
    'nE8wWqloonieQeDsZD',
    'iJJtQkJ/wEh/Dn9gmE',
    'qjnN8i6lhC9Z+TrPkB',
    '1w3p0fpNMgUXJPfpBv',
    'YvmXxQsALaR9BwZytu',
    'eL++qANUcwnb6tnrCP',
  ];
  my $file = CVSLogwatcher::File->new(file => 'some.file', content => $content);
  ok(!$file->validate, 'Validate, implicit pass (1)');
  ok(!$file->validate(qr/MINNIE/i, 'winnie', 'loonie'), 'Validate, explicit pass (2)');
  ok($file->validate(qr/MINNIE/, 'winnie', 'loonie'), 'Validate, explicit deny (3)');
  my @r = $file->validate(qr/MINNIE/, 'winnie', 'loonie');
  is(\@r, array { item qr/MINNIE/; end(); }, 'Validate, return unmatched (4)');
}

{ # content_iter_factory
  my $content = [
    'OG/aTsiK5jhpDwkXE1',
    'vUIQwminnie0XFFYvz',
    'FhZeuVy9chLWAhv5CH',
    'Q9SuzJuunKaWtw+BW7',
    'gJU1Ywinniewc7F09A',
    'G+tYTd2rZe3I4CYh7B',
    'e6vyMtLr4eyXcg/Dfc',
    'nE8wWqloonieQeDsZD',
    'iJJtQkJ/wEh/Dn9gmE',
    'qjnN8i6lhC9Z+TrPkB',
    '1w3p0fpNMgUXJPfpBv',
    'YvmXxQsALaR9BwZytu',
    'eL++qANUcwnb6tnrCP',
  ];
  my $file = CVSLogwatcher::File->new(file => 'some.file', content => $content);
  my $cif = $file->content_iter_factory;
  ref_ok($cif, 'CODE', 'Content iter. factory (1)');
  is($cif->(), 'OG/aTsiK5jhpDwkXE1', 'Content iter. factory (2)');
  is($cif->(), 'vUIQwminnie0XFFYvz', 'Content iter. factory (3)');
  $cif = $file->content_iter_factory(sub ($l) {
    $l =~ 'minnie' || $l =~ 'winnie' || $l =~ 'loonie'
  });
  ref_ok($cif, 'CODE', 'Content iter. factory (4)');
  is($cif->(), 'OG/aTsiK5jhpDwkXE1', 'Content iter. factory (5)');
  is($cif->(), 'FhZeuVy9chLWAhv5CH', 'Content iter. factory (6)');
  my $i = 2; $i++ while($cif->());
  is($i, 10, 'Content iter. factory (7)')
}

{ # is_changed
  my @content1 = (
    '+X7lqAT8pDmtUCDKe', # 0
    '6GKOxlR/4CD1pc5br', # 1
    'nJJrTWiFabAu/or4G', # 2
    'HylWUeoBJ7LWfy8Pt', # 3
    'yJIz9QKNbkX4XH4di', # 4
    'nZg0Qa70epS68uysn', # 5
    'wa0ExiYYN/OLi79M5', # 6
    'TCAyrmv7eS+sE5NlF', # 7
  );
  my (@content2) = @content1;
  my $file1 = CVSLogwatcher::File->new(file => 'file1', content => \@content1);
  my $file2 = CVSLogwatcher::File->new(file => 'file2', content => \@content2);
  ok(!$file1->is_changed($file2), 'Change detection (1)');
  $file2->content->[7] = 'Xyrmv7eS+sX';
  ok($file1->is_changed($file2), 'Change detection (2)');
  delete $file2->content->[7];
  ok($file1->is_changed($file2), 'Change detection (3)');
  delete $file1->content->[7];
  ok(!$file1->is_changed($file2), 'Change detection (4)');
}

{ # save & remove
  my @content = (
    "fHGypPywSzSPJAz\n",
    "p2WJ0ThB1AqXQRk\n",
    "GE0JfDqSSqoJNCB\n",
    "VRJLNJXlKrO9i5v\n",
    "AteLMhYHghmFBVs\n",
    "RiGVLtL0bpveNMm\n",
    "Vei6YDXpJKFqIqm\n",
  );
  my $tmp = Path::Tiny->tempfile;
  my $alttmp = Path::Tiny->tempfile;
  my $tmpdir = Path::Tiny->tempdir;
  my $file = CVSLogwatcher::File->new(file => $tmp, content => \@content);
  my $rv;
  ok(lives { $rv = $file->save }, 'File save (1)');
  ok(-f $tmp, 'File save (2)');
  is($rv->stringify, $tmp->stringify, 'File save (2b)');
  my $file2;
  ok(lives { $file2 = CVSLogwatcher::File->new(file => $tmp) }, 'File save (3)');
  ok(!$file->is_changed($file2));
  # save to alternate destination (complete pathname given)
  ok(lives { $file->save($alttmp) }, 'File save (4)');
  ok(-f $alttmp, 'File save (5)');
  # save to alternate destination (only destination directory given)
  ok(lives { $file->save($tmpdir) }, 'File save (5)');
  ok(-f $tmpdir->child($tmp->basename), 'File save (6)');
  # remove file
  ok(lives { $file2->remove }, 'File remove (1)');
  ok(!-f $tmp, 'File remove (2)');
}

done_testing();
