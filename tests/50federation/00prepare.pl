use File::Basename qw( dirname );

use IO::Socket::IP 0.04; # ->sockhostname
Net::Async::HTTP->VERSION( '0.39' ); # ->GET with 'headers'

use Crypt::NaCl::Sodium;

my $DIR = dirname( __FILE__ );

struct FederationParams => [qw( server_name key_id public_key secret_key )];

prepare "Creating inbound federation HTTP server and outbound federation client",
   requires => [qw( first_home_server )],

   provides => [qw( local_server_name inbound_server outbound_client )],

   do => sub {
      my ( $first_home_server ) = @_;

      my $inbound_server = SyTest::Federation::Server->new;
      $loop->add( $inbound_server );

      provide inbound_server => $inbound_server;

      require IO::Async::SSL;

      $inbound_server->listen(
         host    => "localhost",
         service => "",
         extensions => [qw( SSL )],

         SSL_key_file => "$DIR/server.key",
         SSL_cert_file => "$DIR/server.crt",
      )->on_done( sub {
         my ( $listener ) = @_;
         my $sock = $listener->read_handle;

         my $server_name = sprintf "%s:%d", $sock->sockhostname, $sock->sockport;

         provide local_server_name => $server_name;

         my ( $pkey, $skey ) = Crypt::NaCl::Sodium->sign->keypair;

         my $fedparams = FederationParams( $server_name, "ed25519:1", $pkey, $skey );

         # For now, the federation keystore is just a hash keyed on "origin/keyid"
         my $keystore = {};

         my $outbound_client = SyTest::Federation::Client->new(
            federation_params => $fedparams,
            keystore          => $keystore,
            uri_base          => "https://$first_home_server/_matrix/federation/v1",
         );
         $loop->add( $outbound_client );

         $listener->configure(
            federation_params => $fedparams,
            keystore          => $keystore,
            client            => $outbound_client,
         );

         provide outbound_client => $outbound_client;
      });
   };

# A small test to check that our own federation server simulation is working
# correctly. If this test fails, it *ALWAYS* indicates a failure of SyTest
# itself and not of the homeserver being tested.
test "Checking local federation server",
   requires => [qw( local_server_name inbound_server http_client )],

   check => sub {
      my ( $local_server_name, $inbound_server, $client ) = @_;

      my $key_id = $inbound_server->key_id;

      $client->do_request(
         method => "GET",
         uri    => "https://$local_server_name/_matrix/key/v2/server/$key_id",
      )->then( sub {
         my ( $body ) = @_;
         log_if_fail "Keyserver response", $body;

         require_json_keys( $body, qw( server_name valid_until_ts verify_keys signatures tls_fingerprints ));

         require_json_string( $body->{server_name} );
         $body->{server_name} eq $local_server_name or
            die "Expected server_name to be $local_server_name";

         require_json_number( $body->{valid_until_ts} );
         $body->{valid_until_ts} / 1000 > time or
            die "Key valid_until_ts is in the past";

         keys %{ $body->{verify_keys} } or
            die "Expected some verify_keys";

         exists $body->{verify_keys}{$key_id} or
            die "Expected to find the '$key_id' key in verify_keys";

         require_json_keys( my $key = $body->{verify_keys}{$key_id}, qw( key ));

         require_base64_unpadded( $key->{key} );

         keys %{ $body->{signatures} } or
            die "Expected some signatures";

         $body->{signatures}{$local_server_name} or
            die "Expected a signature from $local_server_name";

         my $signature = $body->{signatures}{$local_server_name}{$key_id} or
            die "Expected a signature from $local_server_name using $key_id";

         require_base64_unpadded( $signature );

         # TODO: verify it?

         require_json_list( $body->{tls_fingerprints} );
         @{ $body->{tls_fingerprints} } > 0 or
            die "Expected some tls_fingerprints";

         foreach ( @{ $body->{tls_fingerprints} } ) {
            require_json_object( $_ );

            # TODO: Check it has keys named by the algorithms
         }

         Future->done(1);
      });
   };

package SyTest::Federation::_Base;

use mro 'c3';
use Protocol::Matrix qw( sign_json );

sub configure
{
   my $self = shift;
   my %params = @_;

   foreach (qw( federation_params keystore )) {
      $self->{$_} = delete $params{$_} if exists $params{$_};
   }

   $self->next::method( %params );
}

sub server_name
{
   my $self = shift;
   return $self->{federation_params}->server_name;
}

sub key_id
{
   my $self = shift;
   return $self->{federation_params}->key_id;
}

sub sign_data
{
   my $self = shift;
   my ( $data ) = @_;

   my $fedparams = $self->{federation_params};

   sign_json( $data,
      secret_key => $fedparams->secret_key,
      origin     => $fedparams->server_name,
      key_id     => $fedparams->key_id,
   );
}

sub get_key
{
   my $self = shift;
   my %params = @_;

   # hashes have keys. not the same as crypto keys. Grr.
   my $hk = "$params{server_name}:$params{key_id}";

   $self->{keystore}{$hk} //= $self->_fetch_key( $params{server_name}, $params{key_id} );
}

package SyTest::Federation::Client;
use base qw( SyTest::Federation::_Base SyTest::HTTPClient );

use MIME::Base64 qw( decode_base64 );
use HTTP::Headers::Util qw( join_header_words );

sub _fetch_key
{
   my $self = shift;
   my ( $server_name, $key_id ) = @_;

   $self->do_request_json(
      method   => "GET",
      full_uri => "https://$server_name/_matrix/key/v2/server/$key_id",
   )->then( sub {
      my ( $body ) = @_;

      defined $body->{server_name} and $body->{server_name} eq $server_name or
         return Future->fail( "Response 'server_name' does not match", matrix => );

      $body->{verify_keys} and $body->{verify_keys}{$key_id} and my $key = $body->{verify_keys}{$key_id}{key} or
         return Future->fail( "Response did not provide key '$key_id'", matrix => );

      $key = decode_base64( $key );

      # TODO: Check the self-signedness of the key response

      Future->done( $key );
   });
}

sub do_request_json
{
   my $self = shift;
   my %params = @_;

   my $uri = $self->full_uri_for( %params );

   my $fedparams = $self->{federation_params};

   my $origin = $fedparams->server_name;
   my $key_id = $fedparams->key_id;

   my %signing_block = (
      method => "GET",
      uri    => $uri->path_query,  ## TODO: Matrix spec is unclear on this bit
      origin => $origin,
      destination => $uri->authority,
   );

   if( defined $params{content} ) {
      $signing_block{content} = $params{content};
   }

   $self->sign_data( \%signing_block );

   my $signature = $signing_block{signatures}{$origin}{$key_id};

   my $auth = "X-Matrix " . join_header_words(
      [ origin => $origin ],
      [ key    => $key_id ],
      [ sig    => $signature ],
   );

   # TODO: SYN-437 synapse does not like OWS between auth-param elements
   $auth =~ s/, +/,/g;

   $self->SUPER::do_request_json(
      %params,
      headers => [
         @{ $params{headers} || [] },
         Authorization => $auth,
      ],
   );
}

package SyTest::Federation::Server;
use base qw( SyTest::Federation::_Base Net::Async::HTTP::Server );

no if $] >= 5.017011, warnings => 'experimental::smartmatch';
use feature qw( switch );

use Carp;

use Protocol::Matrix qw( encode_base64_unpadded verify_json_signature );
use HTTP::Headers::Util qw( split_header_words );
use JSON qw( encode_json );

sub configure
{
   my $self = shift;
   my %params = @_;

   foreach (qw( client )) {
      $self->{$_} = delete $params{$_} if exists $params{$_};
   }

   return $self->SUPER::configure( %params );
}

sub _fetch_key
{
   my $self = shift;
   return $self->{client}->_fetch_key( @_ );
}

sub make_request
{
   my $self = shift;
   return SyTest::HTTPServer::Request->new( @_ );
}

sub on_request
{
   my $self = shift;
   my ( $req ) = @_;

   ::log_if_fail "Incoming federation request", $req;

   my $path = $req->path;
   unless( $path =~ s{^/_matrix/}{} ) {
      $req->respond( HTTP::Response->new( 404, "Not Found", [ Content_Length => 0 ] ) );
      return;
   }

   $self->adopt_future(
      ( # 'key' requests don't need to be signed
         $path =~ m{^key/}
            ? Future->done
            : $self->_check_authorization( $req )
      )->then( sub {
         $self->_dispatch( $path, $req )
      })->else_with_f( sub {
         my ( $f, undef, $name ) = @_;
         return $f unless $name eq "matrix_auth";

         # Turn 'matrix_auth' failures into HTTP responses
         my ( undef, $message ) = @_;
         my $body = encode_json {
            errcode => "M_UNAUTHORIZED",
            error   => $message,
         };

         Future->done( response => HTTP::Response->new(
            403, undef, [
               Content_Length => length $body,
               Content_Type   => "application/json",
            ], $body
         ) );
      })->on_done( sub {
         for ( shift ) {
            when( "response" ) {
               my ( $response ) = @_;
               $req->respond( $response );
            }
            when( "json" ) {
               my ( $data ) = @_;
               $self->sign_data( $data );
               $req->respond_json( $data );
            }
            default {
               croak "Unsure how to handle response type $_";
            }
         }
      })
   );
}

sub _check_authorization
{
   my $self = shift;
   my ( $req ) = @_;

   my $auth = $req->header( "Authorization" ) // "";

   $auth =~ s/^X-Matrix\s+// or
      return Future->fail( "No Authorization of scheme X-Matrix", matrix_auth => );

   # split_header_words gives us a list of two-element ARRAYrefs
   my %auth_params = map { @$_ } split_header_words( $auth );

   defined $auth_params{$_} or
      return Future->fail( "Missing '$_' parameter to X-Matrix Authorization", matrix_auth => ) for qw( origin key sig );

   my $origin = $auth_params{origin};

   my %to_verify = (
      method      => $req->method,
      uri         => $req->as_http_request->uri->path_query,
      origin      => $origin,
      destination => $self->server_name,
      signatures  => {
         $origin => {
            $auth_params{key} => $auth_params{sig},
         },
      },
   );

   if( length $req->body ) {
      my $body = $req->body_json;

      $origin eq $body->{origin} or
         return Future->fail( "'origin' in Authorization header does not match content", matrix_auth => );

      $to_verify{content} = $body;
   }

   $self->get_key(
      server_name => $origin,
      key_id      => $auth_params{key},
   )->then( sub {
      my ( $public_key ) = @_;

      eval { verify_json_signature( \%to_verify,
         public_key => $public_key,
         origin     => $auth_params{origin},
         key_id     => $auth_params{key}
      ) } and return Future->done;

      chomp ( my $message = $@ );
      return Future->fail( $message, matrix_auth => );
   });
}

sub _dispatch
{
   my $self = shift;
   my ( $path, $req ) = @_;

   my @pc = split m{/}, $path;
   my @trial;
   while( @pc ) {
      push @trial, shift @pc;
      if( my $code = $self->can( "on_request_" . join "_", @trial ) ) {
         return $code->( $self, $req, @pc );
      }
   }

   print STDERR "TODO: Respond to request to /_matrix/${\join '/', @trial}\n";

   return Future->done(
      response => HTTP::Response->new(
         404, "Not Found",
         [ Content_Length => 0 ],
      )
   );
}

sub on_request_key_v2_server
{
   my $self = shift;
   my ( $req, $keyid ) = @_;

   my $sock = $req->stream->read_handle;
   my $ssl = $sock->_get_ssl_object;  # gut-wrench into IO::Socket::SSL - see RT105733
   my $cert = Net::SSLeay::get_certificate( $ssl );

   my $algo = "sha256";
   my $fingerprint = Net::SSLeay::X509_digest( $cert, Net::SSLeay::EVP_get_digestbyname( $algo ) );

   my $fedparams = $self->{federation_params};

   Future->done( json => {
      server_name => $fedparams->server_name,
      tls_fingerprints => [
         { $algo => encode_base64_unpadded( $fingerprint ) },
      ],
      valid_until_ts => ( time + 86400 ) * 1000, # +24h in msec
      verify_keys => {
         $fedparams->key_id => {
            key => encode_base64_unpadded( $fedparams->public_key ),
         },
      },
      old_verify_keys => {},
   } );
}
