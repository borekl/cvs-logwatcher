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

1;
