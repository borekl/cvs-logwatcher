#/usr/bin/perl

use strict;
use warnings;
use Test2::V0;

use CVSLogwatcher::Repl;

# creation of an instance works
isa_ok(my $repl = CVSLogwatcher::Repl->new, 'CVSLogwatcher::Repl');

# adding new value should return self
isa_ok($repl->add_value('%A' => '.AAA.'),'CVSLogwatcher::Repl');

# replacement of existing token with its value
is(
  $repl->replace('A%AA'),
  'A.AAA.A',
  'string replace (ex)'
);

# replacement with non-existing token should not change anything
is(
  $repl->replace('A%BA'),
  'A%BA',
  'string replace (nex)'
);

# clone should return another instance of the same class, with the same content
my $clone = $repl->clone;
isa_ok($clone, 'CVSLogwatcher::Repl');
ok($clone ne $repl, 'Clone is not the same object');
is($repl->values, $clone->values, 'Clone content check');

# check clone derivation (clone should have all the values of the source
# instance)
is(
  $clone->replace('A%AA'),
  'A.AAA.A',
  'Clone derivation'
);

# check clone independence (adding value to the source instance should not
# affect the clone)
$repl->add_value('%B' => '.BBB.');
is(
  $clone->replace('X%BX'),
  'X%BX',
  'Clone independence'
);

# adding capture groups
$repl->add_capture_groups('lorem', 'ipsum', 'dolor', 'sit', 'amet');
is(
  $repl->replace('%+0 %+1 %+2 %+3 %+4'),
  'lorem ipsum dolor sit amet',
  'Capture groups (1st time)'
);

# adding capture groups second time should expunge the previous ones
$repl->add_capture_groups('productum', 'locus', 'finis', 'indicat');
is(
  $repl->replace('%+0 %+1 %+2 %+3 %+4'),
  'productum locus finis indicat %+4',
  'Capture groups (2nd time)'
);

# finish
done_testing();
