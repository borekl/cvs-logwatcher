#==============================================================================
# Target configuration and handling
#==============================================================================

package CVSLogwatcher::Target;

use v5.36;
use Moo;

use CVSLogwatcher::Expect;
use CVSLogwatcher::File;
use CVSLogwatcher::Stash;

# full config as parsed from the config file
has config => ( is => 'ro', required => 1 );

# target id
has id => ( is => 'lazy' );

# default administrative group
has defgroup => (
  is => 'ro',
  default => sub ($s) { $s->config->{defgrp} // undef }
);

# filter expressions for filtering configuration
has filter => (
  is => 'ro',
  default => sub ($s) { $s->config->{filter} // [] }
);

# validation list
has validate => (
  is => 'ro',
  default => sub ($s) { $s->config->{validate} // [] }
);

# CVSL::Expect instance
has expect => ( is => 'lazy' );

#------------------------------------------------------------------------------
sub _build_id ($self) { $self->config->{id} }

#------------------------------------------------------------------------------
sub _build_expect ($self) {
  CVSLogwatcher::Expect->new(target => $self);
}

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
# Return true if "validrange" feature is configured correctly
sub has_validrange ($self)
{
  exists $self->config->{validrange}
  && ref $self->config->{validrange}
  && $self->config->{validrange}->@* == 2
}

#------------------------------------------------------------------------------
# Custom predicate for filter
sub has_filter ($self) { return scalar(@{$self->filter}) }

#------------------------------------------------------------------------------
# Return true if the line of configuration is passed through the filter; no
# filter makes everything pass
sub filter_pass ($self, $l)
{
  return 0 == grep { $l =~ /$_/ } @{$self->filter};
}

#------------------------------------------------------------------------------
# Factory function for config validation. The returned function is fed the
# config file line by line and returns list of remaining unmatched regexes; if
# all regexes are matched, the list is empty.
sub validate_checker ($self)
{
  my @regexes = @{$self->validate};

  if(@{$self->validate}) {
    return sub ($l=undef) {
      return @regexes if !@regexes || !defined $l;
      @regexes = grep { $l !~ /$_/ } @regexes;
      return @regexes;
    }
  } else {
    return undef;
  }
}

#------------------------------------------------------------------------------
# Return true if line is ignored, as defined by 'ignoreline' configuration
# option. Returns false if no ignoreline is defined.
sub is_ignored ($self, $l)
{
  my $re = $self->config->{ignoreline} // undef;
  return 1 if $re && $l =~ /$re/;
  return undef;
}

#------------------------------------------------------------------------------
# Add explicitly defined files, if they exist
sub add_files ($self, $files)
{
  my $tcfg = $self->config;
  my $cfg = CVSLogwatcher::Config->instance;

  if(exists $tcfg->{files} && $tcfg->{files}->@*) {
    foreach my $file ($tcfg->{files}->@*) {
      my $rfile = $cfg->repl->replace($file);
      push(
        @$files, CVSLogwatcher::File->new(file => $rfile, target => $self)
      ) if -r $rfile;
    }
  }
}

#------------------------------------------------------------------------------
# Invoke custom target action if it is defined. The argument is the Host
# instance
sub action ($self, $host)
{
  my $logger = CVSLogwatcher::Config->instance->logger;
  my $tag = $host->tag;

  if($self->config->{action}) {
    $logger->debug(qq{[$tag] Invoking action callback}) if $tag;
    $self->config->{action}->(
      CVSLogwatcher::Stash->instance->host($host->name),
      $host->data
    );
  }
}

#------------------------------------------------------------------------------
# Invoke custom commit usr/message getter if defined
sub commit_info ($self, $match)
{
  my $stash = CVSLogwatcher::Stash->instance->host($match->{host});
  my ($user, $msg);

  if(exists $self->config->{commit}) {
    if($self->config->{commit}{user}) {
      $user = $self->config->{commit}{user}->($stash, $match)
    }
    if($self->config->{commit}{msg}) {
      $msg = $self->config->{commit}{msg}->($stash, $match)
    }
  }

  return ($user, $msg);
}

1;
