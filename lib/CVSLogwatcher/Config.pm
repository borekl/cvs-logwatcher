#==============================================================================
# Encapsulate loading and managing configuration.
#==============================================================================

package CVSLogwatcher::Config;

use Moo;
use warnings;
use strict;
use v5.10;
use experimental 'signatures';
use JSON;
use Path::Tiny;

use CVSLogwatcher::Logfile;
use CVSLogwatcher::Target;

# base directory
has basedir => ( is => 'ro', required => 1 );

# main configuration file
has config_file => (
  is => 'ro', required => 1,
  isa => sub ($cfg) {
    die "Config file $cfg not found" unless -r $cfg;
  }
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

# repository base dir
has repodir => ( is => 'lazy' );

# logfiles
has logfiles => ( is => 'lazy' );

# targets
has targets => ( is => 'lazy' );

#------------------------------------------------------------------------------
# load and parse configuration
sub _build_config ($self)
{
  my $file = $self->config_file;
  return JSON->new->relaxed(1)->decode(path($file)->slurp);
}

#------------------------------------------------------------------------------
# load and parse keyring
sub _build_keyring ($self)
{
  my $cfg = $self->config;
  my $krg_file = $cfg->{config}{keyring} // undef;

  if($krg_file) {
    $krg_file = $self->_config_dir->child($krg_file);
    die "Cannot find or access keyring file $krg_file" unless -r $krg_file;
    return JSON->new->relaxed(1)->decode(path($krg_file)->slurp);
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
# Repository base dir
sub _build_repodir ($self)
{
  my $cfg = $self->config;
  my $dir = path($cfg->{rcs}{rcsrepo} // 'data');

  $dir = $self->basedir->child($dir) unless $dir->is_absolute;

  return $dir;
}

#------------------------------------------------------------------------------
sub _build_logfiles ($self)
{
  my $cfg = $self->config;
  my %logs;

  for my $logid (keys %{$cfg->{logfiles}}) {
    my $log = $cfg->{logfiles}{$logid};
    my $logfile = path $log->{filename};
    # handle relative filenames
    $logfile = $cfg->basedir->child($logfile) if substr($logfile, 0, 1) ne '/';
    # ignore unreadable logfiles
    next if !-r $logfile;
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
    map { CVSLogwatcher::Target->new(config => $_) } @{$cfg->{targets}}
  ];
}

#------------------------------------------------------------------------------
# File::Tail parameters
sub tailparam ($self, $p)
{
  my $cfg = $self->config;

  if($p eq 'tailmax') { return $cfg->{config}{tailmax} // 3600 }
  elsif($p eq 'tailint') { return $cfg->{config}{tailint} // 4 }
  elsif($p eq 'expmax') { return $cfg->{config}{expmax} // 60 }

  die "Invalid tailparam argument '$p'";
}

#------------------------------------------------------------------------------
# RCS binaries
sub rcs ($self, $p)
{
  my $cfg = $self->config;

  if($p eq 'rcsctl') { return $cfg->{rcs}{rcsctl} // '/usr/bin/rcs' }
  elsif($p eq 'rcsci') { return $cfg->{rcs}{rcsci} // '/usr/bin/ci' }
  elsif($p eq 'rcsco') { return $cfg->{rcs}{rcsco} // '/usr/bin/co' }

  die "Invalid rcs argument '$p'";
}

#------------------------------------------------------------------------------
# Ping configuration
sub ping ($self) { $self->config->{ping} // undef }

#------------------------------------------------------------------------------
# Return true if the user passed as argument is on the ignore list
sub is_ignored_user ($self, $u)
{
  my $cfg = $self->config;

  if(
    exists $cfg->{ignoreusers}
    && ref $cfg->{ignoreusers}
    && grep { lc eq lc $u } @{$cfg->{ignoreusers}}
  ) {
    return 1;
  }

  return undef;
}

#------------------------------------------------------------------------------
# Return true if the host passed as argument is on the ignore list
sub is_ignored_host ($self, $h)
{
  my $cfg = $self->config;

  if(
    exists $cfg->{ignorehosts}
    && ref $cfg->{ignorehosts}
    && grep { $h =~ /$_/ } @{$cfg->{ignorehosts}}
  ) {
    return 1;
  }

  return undef;
}

#------------------------------------------------------------------------------
sub iterate_logfiles ($self, $cb)
{
  foreach my $log (keys %{$self->logfiles}) {
    $cb->($self->logfiles->{$log});
  }
}

#------------------------------------------------------------------------------
sub find_target ($self, $logid, $host)
{
  my $cfg = $self->config;

  # remove domain from hostname
  $host =~ s/\..*$//g if $host;

  foreach my $target (@{$self->targets}) {
    # "logfile" condition
    next if
      exists $target->config->{'logfile'}
      && $target->config->{'logfile'} ne $logid;
    # "hostmatch" condition
    next if $host && !$target->match_hostname($host);
    # no mismatch, target found
    if(wantarray()) {
      return ($target->id, $target->config);
    } else {
      return $target->id;
    }
  }
}

1;
