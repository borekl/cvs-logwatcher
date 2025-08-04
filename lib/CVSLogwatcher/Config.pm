#==============================================================================
# Encapsulate loading and managing configuration.
#==============================================================================

package CVSLogwatcher::Config;
use Moo;
with 'MooX::Singleton';

use warnings;
use strict;
use v5.10;
use experimental 'signatures', 'postderef';
use Carp;
use Path::Tiny;
use Log::Log4perl qw(get_logger);

use CVSLogwatcher::Logfile;
use CVSLogwatcher::Target;
use CVSLogwatcher::Repl;
use CVSLogwatcher::Repo::RCS;
use CVSLogwatcher::Repo::Git;

# base directory
has basedir => ( is => 'ro', required => 1, coerce => sub ($b) { path $b } );

# main configuration file
has config_file => (
  is => 'ro', required => 1,
  isa => sub ($cfg) {
    die "Config file $cfg not found" unless $cfg eq '-' || -r $cfg
  },
  coerce => sub ($cfg) { $cfg->isa('Path::Tiny') ? $cfg : path($cfg) },
);

# configuration directory, this is automatically filled in from 'config_file'
has _config_dir => (
  is => 'ro', lazy => 1,
  default => sub ($s) { path($s->config_file)->absolute->parent },
);

# parsed configuration
has config => ( is => 'lazy' );

# parsed keyring file
has keyring => ( is => 'lazy');

# scratch directory
has tempdir => ( is => 'lazy' );

# log directory
has logprefix => ( is => 'lazy' );

# logfiles
has logfiles => ( is => 'lazy' );

# targets
has targets => ( is => 'lazy' );

# replacements
has repl => ( is => 'lazy' );

# Log4Perl logger instance
has logger => ( is => 'lazy' );

# configuration repositories
has repos => ( is => 'lazy' );

#-------------------------------------------------------------------------------
# run a perl script from file and return its return value, if the file passed
# in is '-', read the script from stdin
sub _do_script ($file)
{
  my $config;

  # slurp from stdin if told so
  if($file eq '-') {
    local $/;
    $/ = undef;
    binmode(STDIN, ':unix:encoding(UTF-8)');
    $config = <STDIN>;
  }

  # otherwise read specified file
  else {
    $config = $file->slurp_utf8;
  }

  # process the received config
  my $re = eval($config);
  die $@ if $@;
  return $re;
}

#------------------------------------------------------------------------------
# load and parse configuration
sub _build_config ($self)
{
  return _do_script($self->config_file);
}

#------------------------------------------------------------------------------
# load and parse keyring
sub _build_keyring ($self)
{
  my $cfg = $self->config;
  my $file = $cfg->{config}{keyring} // undef;

  if($file) {
    $file = $self->_config_dir->child($file);
    die "Cannot find or access keyring file $file" unless -r $file;
    return _do_script($file);
  }

  return {};
}

#------------------------------------------------------------------------------
# get scratch directory; if config.tempdir gives absolute path use that,
# otherwise root the relative path at FindBin's $Bin (that is the directory
# the executing script is in). If config.tempdir
sub _build_tempdir ($self)
{
  my $cfg = $self->config;
  my $d = $self->basedir;

  if(
    exists $cfg->{config}
    && exists $cfg->{config}{tempdir}
    && $cfg->{config}{tempdir}
  ) {
    $d = path $cfg->{config}{tempdir};
    $d = $self->basedir->child($cfg->{config}{tempdir}) unless $d->is_absolute;
  }

  die "Temporary directory '$d' not found" unless $d->is_dir;
  return $d;
}

#------------------------------------------------------------------------------
# handle log directory, ie. the main directory where logs to be observed are
# stored in (usually /var/log)
sub _build_logprefix ($self)
{
  my $cfg = $self->config;

  die 'No config.logprefix defined'
  unless $cfg->{config}{logprefix};

  return path $cfg->{config}{logprefix};
}

#------------------------------------------------------------------------------
sub _build_logfiles ($self)
{
  my $cfg = $self->config;
  my %logs;

  for my $logid (keys $cfg->{logfiles}->%*) {
    my $log = $cfg->{logfiles}{$logid};
    my $logfile = path $log->{filename};
    # handle relative filenames
    $logfile = $cfg->basedir->child($logfile) if substr($logfile, 0, 1) ne '/';
    # instantiate a logfile
    $logs{$logid} = CVSLogwatcher::Logfile->new(
      id => $logid,
      file => $logfile,
      matchre => $log->{match}
    );
  }

  return \%logs;
}

#------------------------------------------------------------------------------
sub _build_targets ($self)
{
  my $cfg = $self->config;

  return [
    map { CVSLogwatcher::Target->new(config => $_) } $cfg->{targets}->@*
  ];
}

#------------------------------------------------------------------------------
# Master Repl instance, initialized with keyring and %D (scratch dir)
sub _build_repl ($self)
{
  CVSLogwatcher::Repl->new(
    $self->keyring->%*,
    '%D' => $self->tempdir->stringify
  );
}

#------------------------------------------------------------------------------
# Log4Perl Logger initialization
sub _build_logger ($self)
{
  # ensure Log4Perl configuration is available
  die "Logging configurartion 'cfg/logging.conf' not found or not readable\n"
  unless -r $self->basedir->child('cfg/logging.conf');

  # initialize
  Log::Log4perl->init_and_watch("cfg/logging.conf", 60);
  my $logger = get_logger('CVS::Main');
  return $logger;
}

#-------------------------------------------------------------------------------
# create Repo instances, that represent individual repositories that the
# application shall be storing files into
sub _build_repos ($self)
{
  my @repos;

  foreach my $r ($self->config->{repos}->@*) {
    my $type = delete $r->{type};
    # adapt the base to be an absolute path
    $r->{base} = path($r->{base});
    if($r->{base}->is_relative) {
      $r->{base} = $self->basedir->child($r->{base});
    }
    # instantiate the repositories
    if($type eq 'Git') {
      push(@repos, CVSLogwatcher::Repo::Git->new(%$r));
    } elsif($type eq 'RCS') {
      push(@repos, CVSLogwatcher::Repo::RCS->new(%$r));
    } else {
      die "Unsupported repository type '" . $type . "'";
    }
  }

  return \@repos;
}

#------------------------------------------------------------------------------
# RCS binaries
sub rcs ($self, $p)
{
  my $cfg = $self->config;

  if($p eq 'rcsctl') { return $cfg->{rcs}{rcsctl} // 'rcs' }
  elsif($p eq 'rcsci') { return $cfg->{rcs}{rcsci} // 'ci' }
  elsif($p eq 'rcsco') { return $cfg->{rcs}{rcsco} // 'co' }

  die "Invalid rcs argument '$p'";
}

#------------------------------------------------------------------------------
# Ping configuration
sub ping ($self) { $self->config->{ping} // undef }

#------------------------------------------------------------------------------
# Return true if the user passed as argument is on the ignore list
sub is_ignored_user ($self, $u)
{
  exists $self->config->{ignoreusers}
  && ref $self->config->{ignoreusers}
  && grep { lc eq lc $u } $self->config->{ignoreusers}->@*;
}

#------------------------------------------------------------------------------
# Return true if the host passed as argument is on the ignore list
sub is_ignored_host ($self, $h)
{
  exists $self->config->{ignorehosts}
  && ref $self->config->{ignorehosts}
  && grep { $h =~ /$_/ } $self->config->{ignorehosts}->@*;
}

#------------------------------------------------------------------------------
sub iterate_matches ($self, $cb)
{
  TOP: foreach my $logid (sort keys $self->logfiles->%*) {
    foreach my $match_cfg_entry ($self->logfiles->{$logid}->matchre->@*) {
      last TOP if $cb->($self->logfiles->{$logid}, $match_cfg_entry->[0]);
    }
  }
}

#------------------------------------------------------------------------------
sub find_target ($self, $matchid, $host)
{
  my $cfg = $self->config;

  # remove domain from hostname
  $host =~ s/\..*$//g if $host;

  foreach my $target ($self->targets->@*) {
    # both single matchids and arrays of multiple matchids are supported
    my $target_matchid = $target->config->{'matchid'} // [];
    $target_matchid = [ $target_matchid ] unless ref $target_matchid;
    # "logfile" condition
    next unless grep { $_ eq $matchid } @$target_matchid;
    # "hostmatch" condition
    next if $host && !$target->match_hostname($host);
    # no mismatch, target found
    return $target;
  }
}

#------------------------------------------------------------------------------
# Return target instance by id
sub get_target ($self, $id)
{
  my ($target) = grep { $_->id eq $id } $self->targets->@*;
  return $target;
}

#------------------------------------------------------------------------------
# Gets admin group name from hostname. Admin group is decided based on
# regexes define in "groups" top-level config object.
sub admin_group ($self, $host)
{
  my $cfg = $self->config;

  for my $grp (keys $cfg->{'groups'}->%*) {
    for my $re_src ($cfg->{'groups'}{$grp}->@*) {
      my $re = qr/$re_src/i;
      return $grp if $host =~ /$re/;
    }
  }
  return undef;
}

#------------------------------------------------------------------------------
# Verify that a match id exists, this is only used to validate command-line
sub exists_matchid ($self, $matchid)
{
  my $cfg = $self->config;

  foreach my $logfile (keys $cfg->{logfiles}->%*) {
    foreach my $mid ($cfg->{logfiles}{$logfile}{match}->@*) {
      return 1 if $mid->[0] eq $matchid;
    }
  }

  return 0;
}

1;
