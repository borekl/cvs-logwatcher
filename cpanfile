requires 'perl', '5.036';

requires 'Expect';
requires 'Feature::Compat::Try';
requires 'File::chdir';
requires 'Git::Raw';
requires 'IO::Async';
requires 'IPC::Run';
requires 'Mojo::Log';
requires 'Moo';
requires 'MooX::Singleton';
requires 'Net::SFTP::Foreign';
requires 'Path::Tiny';
requires 'Perl6::Form';
requires 'Term::ReadKey';

on 'test' => sub {
  requires 'Test2::V0';
};
