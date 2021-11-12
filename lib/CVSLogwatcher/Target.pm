#==============================================================================
# Target configuration and handling
#==============================================================================

package CVSLogwatcher::Target;

use Moo;
use warnings;
use strict;
use experimental 'signatures';

has config => ( is => 'ro', required => 1 );
has id => ( is => 'lazy' );
has defgroup => (
  is => 'ro', lazy => 1,
  default => sub ($s) { $s->config->{defgrp} // undef }
);

sub _build_id ($self) { $self->config->{id} }

#------------------------------------------------------------------------------
# Function to match hostname (obtained from logfile) against an array of rules
# and decide the result (MATCH or NO MATCH).
#
# A hostname is considered a rule match when all conditions in the rule are
# evaluated as matching. A hostname is considered a ruleset match when at
# least one rule results in a match.
#
# Following conditions are supported in a rule:
#
# {
#   includere => [],
#   excludere => [],
#   includelist => [],
#   excludelist => [],
# }
#
sub match_hostname ($self, $hostname)
{
  my $cfg = $self->config;
  my $rules = $cfg->{hostmatch} // [];

  # empty list of rules or completely misssing 'hostmatch' key is taken as an
  # unconditional match
  return 1 if !@$rules;

  # rules iteration
  foreach my $rule (@$rules) {

    my ($match_incre, $match_inclst, $match_excre, $match_exclst);

    # 'includere' condition
    if(exists $rule->{'includere'}) {
      for my $re (@{$rule->{'includere'}}) {
        $match_incre ||= ($hostname =~ /$re/i);
      }
    }

    # 'includelist' condition
    if(exists $rule->{'includelist'}) {
      for my $en (@{$rule->{'includelist'}}) {
        $match_inclst ||= (lc($hostname) eq lc($en));
      }
    }

    # 'excludere' condition
    if(exists $rule->{'excludere'}) {
      my $match_excre_local = 'magic';
      for my $re (@{$rule->{'excludere'}}) {
        $match_excre_local &&= ($hostname !~ /$re/i);
      }
      $match_excre = $match_excre_local eq 'magic' ? '' : $match_excre_local
    }

    # 'excludelist' condition
    if(exists $rule->{'excludelist'}) {
      my $match_exclst_local = 'magic';
      for my $en (@{$rule->{'excludelist'}}) {
        $match_exclst_local &&= (lc($hostname) ne lc($en));
      }
      $match_exclst = $match_exclst_local eq 'magic' ? '' : $match_exclst_local
    }

    # evaluate the result of current rule
    my $result = 1;
    for my $val ($match_incre, $match_inclst, $match_excre, $match_exclst) {
      if(
        defined $val
        && !$val
      ) {
        $result = '';
      }
    }

    return 1 if $result;
  }

  return '';
}

#------------------------------------------------------------------------------
# Return true if the target has the option given as an argument
sub has_option ($self, $o)
{
  my $cfg = $self->config;

  if(
    exists $cfg->{options}
    && ref $cfg->{options}
    && grep { $_ eq $o } @{$cfg->{options}}
  ) {
    return 1;
  } else {
    return undef;
  }
}

#------------------------------------------------------------------------------
# Validrange factory; if there is valid 'validrange' specification, return a
# coderef. The returned function receives all lines of a configuration file,
# sequentially and for each line returns true or false given if they are inside
# a specified range.
sub validrange ($self)
{
  my $cfg = $self->config;

  if(
    exists $cfg->{validrange}
    && ref $cfg->{validrange}
    && @{$cfg->{validrange}} == 2
  ) {
    my ($in, $out) = @{$cfg->{validrange}};
    my $in_range = defined $in ? 0 : 1;
    return sub ($l) {
      my $re;
      $in_range = 1 if $in_range == 0 && $l =~ /$in/;
      $re = ($in_range == 1);
      $in_range = 2 if $in_range == 1 && $out && $l =~ /$out/;
      return $re;
    }
  } else {
    return undef;
  }
}

1;
