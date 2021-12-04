#==============================================================================
# Token replacement handling.
#==============================================================================

package CVSLogwatcher::Repl;

use Moo;
use v5.12;
use warnings;
use strict;
use experimental 'signatures';

has values => ( is => 'ro', default => sub { {} } );

#------------------------------------------------------------------------------
# Allow initial replacement to be supplied to the constructor
sub BUILD ($self, $args)
{
  foreach my $key (keys %$args) {
    $self->add_value($key, $args->{$key});
  }
}

#------------------------------------------------------------------------------
# Perform token replacement.
sub replace ($self, $s)
{
  return '' if !$s;

  my $values = $self->values;

  for my $k (keys %$values) {
    my $v = $values->{$k};
    $k = quotemeta($k);
    $s =~ s/$k/$v/g;
  }

  return $s;
}

#------------------------------------------------------------------------------
# Add a new value to token store
sub add_value ($self, %args)
{
  foreach my $key (keys %args) {
    $self->values->{$key} = $args{$key};
  }
  return $self;
}

#------------------------------------------------------------------------------
# Clone this instance
sub clone ($self)
{
  return CVSLogwatcher::Repl->new(
    %{$self->values}
  );
}

#------------------------------------------------------------------------------
# This function adds the list of arguments into %replacements under keys
# %+0, %+1 etc. It also removes all keys that are in this form (ie. purges
# previous replacements).
# This is used to enable using capture groups in expect response strings.
sub add_capture_groups ($self, @g)
{
  # purge old values
  for my $key (keys %{$self->values}) {
    delete $self->values->{$key} if $key =~ /^%\+\d$/;
  }

  # add new values
  foreach my $i (keys @g) {
    $self->add_value( sprintf('%%+%d', $i), $g[$i]);
  }
}

1;
