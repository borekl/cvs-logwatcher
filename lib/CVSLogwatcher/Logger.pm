#==============================================================================
# Logging
#==============================================================================

package CVSLogwatcher::Logger;

use v5.36;
use Moo;
with 'MooX::Singleton';

use Mojo::Log;

# Mojo::Log instance
has _logger => ( is => 'ro', default => sub { Mojo::Log->new });

# logging prefix
has _prefix => ( is => 'ro', default => 'cvs' );

#-------------------------------------------------------------------------------
# logging functions
sub info ($self, $msg, @args) {
  $self->_logger->info(sprintf("[%s] $msg", $self->_prefix, @args))
}
sub debug ($self, $msg, @args) {
  $self->_logger->debug(sprintf("[%s] $msg", $self->_prefix, @args))
}
sub warn ($self, $msg, @args) {
  $self->_logger->warn(sprintf("[%s] $msg", $self->_prefix, @args))
}
sub error ($self, $msg, @args) {
  $self->_logger->error(sprintf("[%s] $msg", $self->_prefix, @args))
}
sub fatal ($self, $msg, @args) {
  $self->_logger->fatal(sprintf("[%s] $msg", $self->_prefix, @args))
}

#-------------------------------------------------------------------------------
# Create a clone of the instance with different prefix
sub prefix ($self, $prefix)
{
  CVSLogwatcher::Logger->new(_prefix => $prefix, logger => $self->_logger)
}

#-------------------------------------------------------------------------------
sub level ($self, $level) { $self->_logger->level($level) }

1;
