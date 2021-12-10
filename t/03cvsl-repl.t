#/usr/bin/perl

use strict;
use warnings;
use CVSLogwatcher::Repl;

use Test::More;

# creation of an instance works
my $repl = CVSLogwatcher::Repl->new;
ok(
  defined $repl && ref $repl && $repl->isa('CVSLogwatcher::Repl'),
  'instance creation'
);

# adding new value should return self
ok(
  $repl->add_value('%A' => '.AAA.')->isa('CVSLogwatcher::Repl'),
  'add key/value'
);

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
ok(
  $clone->isa('CVSLogwatcher::Repl')
  && $clone ne $repl
  && scalar(keys $repl->values->%*) == scalar(keys $clone->values->%*),
  'clone instance'
);

# check clone derivation (clone should have all the values of the source
# instance)
is(
  $clone->replace('A%AA'),
  'A.AAA.A',
  'clone derivation'
);

# check clone independence (adding value to the source instance should not
# affect the clone)
$repl->add_value('%B' => '.BBB.');
is(
  $clone->replace('X%BX'),
  'X%BX',
  'clone independence'
);

# adding capture groups
$repl->add_capture_groups('lorem', 'ipsum', 'dolor', 'sit', 'amet');
is(
  $repl->replace('%+0 %+1 %+2 %+3 %+4'),
  'lorem ipsum dolor sit amet',
  'capture groups (1st time)'
);

# adding capture groups second time should expunge the previous ones
$repl->add_capture_groups('productum', 'locus', 'finis', 'indicat');
is(
  $repl->replace('%+0 %+1 %+2 %+3 %+4'),
  'productum locus finis indicat %+4',
  'capture groups (2nd time)'
);

done_testing();
