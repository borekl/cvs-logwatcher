package CVSLogwatcher::Target;

# target is the next link after a logfile match has occurred; it is selected
# by its matchid property, which contains one ore more match identifications
# that link it to the regular expressions; the target then defines how such
# match is to be handled, how configuration is retrieved from remote device,
# how it is extracted from received file(s) and how it is commited into defined
# repositories

use v5.36;
use Moo;
with 'CVSLogwatcher::Roles::Logger';

use CVSLogwatcher::Action::Expect;
use CVSLogwatcher::Action::SFTP;
use CVSLogwatcher::Action::Null;
use CVSLogwatcher::File;
use CVSLogwatcher::Stash;

# full config as parsed from the config file, it is used to populate some of
# the other attributes
has target_config => ( is => 'ro', required => 1 );

# these come directly from the configuration
has id =>         ( is => 'ro', required => 1 );
has defgrp =>     ( is => 'ro' );
has matchid =>    ( is => 'ro', default => sub {[]} );
has hostname =>   ( is => 'ro', predicate => 1 );
has filter =>     ( is => 'ro' );
has validate =>   ( is => 'ro', predicate => 1 );
has minsize =>    ( is => 'ro', predicate => 1 );
has action =>     ( is => 'lazy' );
has options =>    ( is => 'ro', default => sub {[]} );
has validrange => ( is => 'ro' );
has ignoreline => ( is => 'ro', predicate => 1 );
has files =>      ( is => 'ro', default => sub {[]} );

# CVSL::Repl instance
has repl => ( is => 'ro', required => 1);

#------------------------------------------------------------------------------
around BUILDARGS => sub ($orig, $class, %args)
{
  if($args{target_config} && ref $args{target_config}) {
    my $tcfg = $args{target_config};
    # scalar attributes
    foreach my $key (qw(id defgrp minsize)) {
      if($tcfg->{$key}) { $args{$key} = $tcfg->{$key} }
    }
    # array attributes
    foreach my $key (qw(filter validate options validrange ignoreline files)) {
      if($tcfg->{$key}) {
        if(!ref($tcfg->{$key})) { $args{$key} = [ $tcfg->{$key} ] }
        else { $args{$key} = $tcfg->{$key} }
      }
    }
  }
  return \%args;
};

#------------------------------------------------------------------------------
sub _build_action ($self)
{
  my $logger = $self->logger;

  if(exists $self->target_config->{expect}) {
    CVSLogwatcher::Action::Expect->new(
      target => $self, logger => $logger
    );
  } elsif(exists $self->target_config->{sftp}) {
    return CVSLogwatcher::Action::SFTP->new(target => $self, logger => $logger);
  } else {
    return CVSLogwatcher::Action::Null->new(target => $self);
  }
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
  my $rules = $self->target_config->{hostmatch} // [];

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
  grep { $_ eq $o } $self->options->@*;
}

#------------------------------------------------------------------------------
# Return true if "validrange" feature is configured correctly
sub has_validrange ($self)
{
  $self->validrange
  && ref $self->validrange
  && $self->validrange->@* == 2
}

#------------------------------------------------------------------------------
# Custom predicate for filter
sub has_filter ($self)
{
  $self->filter
  && ref $self->filter
  && $self->filter->@*
}

#------------------------------------------------------------------------------
# Return true if the line of configuration is passed through the filter; no
# filter makes everything pass
sub filter_pass ($self, $l)
{
  return 0 == grep { $l =~ /$_/ } @{$self->filter};
}

#------------------------------------------------------------------------------
# Return true if line is ignored, as defined by 'ignoreline' configuration
# option. Returns false if no ignoreline is defined.
sub is_ignored ($self, $l)
{
  if($self->has_ignoreline) {
    foreach my $re ($self->ignoreline->@*) {
      return 1 if $l =~ /$re/;
    }
  }

  return undef;
}

#------------------------------------------------------------------------------
# Add explicitly defined files, if they exist
sub add_files ($self, $files)
{
  if($self->files->@*) {
    foreach my $file ($self->files->@*) {
      my $rfile = $self->repl->replace($file);
      push(
        @$files, CVSLogwatcher::File->new(file => $rfile, target => $self)
      ) if -r $rfile;
    }
  }
}

#------------------------------------------------------------------------------
# Invoke custom target action if it is defined. The argument is the Host
# instance
sub custom_action ($self, $host)
{
  my $logger = $self->logger->prefix($host->tag) if $host->tag;

  if($self->target_config->{action}) {
    $logger->debug('Invoking action callback') if $logger;
    $self->target_config->{action}->(
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

  $user = $match->{user} // 'unknown';
  $msg = $match->{msg} if exists $match->{msg};

  if(exists $self->target_config->{commit}) {
    if($self->target_config->{commit}{user}) {
      $user = $self->target_config->{commit}{user}->($stash, $match)
    }
    if($self->target_config->{commit}{msg}) {
      $msg = $self->target_config->{commit}{msg}->($stash, $match)
    }
  }

  return ($user, $msg);
}

#------------------------------------------------------------------------------
# returns true if this target has either expect or sftp configured
sub has_retrieval ($self)
{
  return $self->target_config->{expect} || $self->target_config->{sftp}
}


1;
