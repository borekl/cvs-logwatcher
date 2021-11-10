#==============================================================================
# Encapsulate loading and managing configuration.
#==============================================================================

package CVSLogwatcher::Config;

use Moo;
use warnings;
use strict;
use experimental 'signatures';
use JSON;
use Path::Tiny;

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

# parse keyring file
has keyring => ( is => 'lazy');

# scratch direcotry
has tempdir => ( is => 'lazy' );

# log directory
has logprefix => ( is => 'lazy' );

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

1;
