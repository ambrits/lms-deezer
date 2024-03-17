package Plugins::Deezer::Plugin;

use strict;
use Async::Util;
use Tie::Cache::LRU;

use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);

use Plugins::Deezer::API::Auth;
use Plugins::Deezer::API::Async;
use Plugins::Deezer::ProtocolHandler;
use Plugins::Deezer::PodcastProtocolHandler;
use Plugins::Deezer::Custom;

my $log = Slim::Utils::Log->addLogCategory({
	'category'    => 'plugin.deezer',
	'description' => 'PLUGIN_DEEZER_NAME',
});

my $prefs = preferences('plugin.deezer');

# see note on memorizing feeds for different dispatches
my %rootFeeds;
tie %rootFeeds, 'Tie::Cache::LRU', 64;

# Notes for the forgetful on feeds

# We need a 'play' with a URL, not a CODE in items for actions to be visible. Unfortunately,
# then LMS forces favorite's type to be 'audio' and that prevents proper explodePlayList when
# browsing (not playing) favorite later (because 'audio' type don't need to be 'exploded'
# except for playing. This should be fixed in https://github.com/LMS-Community/slimserver/pull/1008

# Also, don't use a URL for 'url' instead of a CODE otherwise explodePlaylist is used when
# browsing and then the passthrough is ignored and obviously anything important there is lost
# or it would need to be in the URL as well.

# Similiarly, if type is 'audio' then the OPML manager does not need to call explodePlaylist
# and if we also add an 'info' action this can be called when clicking on the item (classic)
# or on the (M)ore icon. If there is no 'info' action, clicking on an 'audio' item displays
# little about it, except bitrate and duration fio set in the item (only for classic)

# Also, when type is not 'audio', we can set an 'items' action that is executed in classic
# when clicking on item and won't make M(ore) context menu visible and it is ignored in material
# so that's a bit useless.

# Actions can be directly in the feed in which case they are global on they can be in each item
# named 'itemActions'. They use cliQuery and require a AddDispatch with a matching command. See
# comment on finding a root/anchor when using JSONRPC interface
# The 'fixedParams' are hashes on strings that will be retrieved by getParams or using 'variables'
# they can be extracted from items themselves. It's an array of pairs of key in the item and key
# in the query variables => [ 'url', 'url' ]

# We can't re-use Slim::Menu::TrackInfo to create actions using the 'menu' method as it can only
# create track objects for items that are in the database, unless the ObjectForUrl has some way
# to have PH overload a method to create the object, but I've not found that anywhere in Schema
# Now, the PH can overload trackInfoUrl which shortcuts the whole Slim::Menu::TrackInfo and returns
# a feed but I'm not sure I see the real benefit in doing that, especially because this does not
# exist for albumInfo/artistInfo and also you still need to manually create the action in items.

# TODO
# - add some notes on creating usable links on trackInfo/albuminfo/artistsinfo
# - fix the podcast title as part of the passthrough
# - an URL to Deezer track/album/artist location (link provided by Deezer)

sub initPlugin {
	my $class = shift;

	$prefs->init({
		quality => 'HIGH',
		serial => '29436f4b2c5b2b552e4c221b2d7c7a4e7a336c002d7278512e486f1f2c677d432b1c224e29522c0b280e7f42750f7b43794a271c7d652b06744c5454795f6c4e781f51197d742e077b5b344e7b0e694d7e4c271e2c1c7c032c4f794e786060062b4260432f306b40',
	});

	Plugins::Deezer::API::Auth->init();
	Plugins::Deezer::ProtocolHandler->init();
	Plugins::Deezer::API::Async->init();

	if (main::WEBUI) {
		require Plugins::Deezer::Settings;
		Plugins::Deezer::Settings->new();
	}

	Slim::Player::ProtocolHandlers->registerHandler('deezer', 'Plugins::Deezer::ProtocolHandler');
	Slim::Player::ProtocolHandlers->registerHandler('deezerpodcast', 'Plugins::Deezer::PodcastProtocolHandler');
	Slim::Music::Import->addImporter('Plugins::Deezer::Importer', { use => 1 });

	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => 'deezer',
		menu   => 'apps',
		is_app => 1,
	);

	Slim::Menu::TrackInfo->registerInfoProvider( deezer => (
		after => 'bottom',
		func  => \&trackInfoMenu,
	) );

	Slim::Menu::ArtistInfo->registerInfoProvider( deezer => (
		after => 'bottom',
		func  => \&artistInfoMenu,
	) );

	Slim::Menu::AlbumInfo->registerInfoProvider( deezer => (
		after => 'bottom',
		func  => \&albumInfoMenu,
	) );

#  |requires Client
#  |  |is a Query
#  |  |  |has Tags
#  |  |  |  |Function to call
	Slim::Control::Request::addDispatch( [ 'deezer_info', 'items', '_index', '_quantity' ],	[ 1, 1, 1, \&menuInfoWeb ]	);
	Slim::Control::Request::addDispatch( [ 'deezer_info', 'jive' ],	[ 1, 1, 1, \&menuInfoJive ]	);
	Slim::Control::Request::addDispatch( [ 'deezer_browse', 'items' ],	[ 1, 1, 1, \&menuBrowse ]	);
	Slim::Control::Request::addDispatch( [ 'deezer_browse', 'playlist', '_method' ],	[ 1, 1, 1, \&menuBrowse ]	);

=comment
	Slim::Menu::GlobalSearch->registerInfoProvider( deezer => (
		func => sub {
			my ( $client, $tags ) = @_;

			return {
				name  => cstring($client, Plugins::Spotty::Deezer::getDisplayName()),
				items => [ map { delete $_->{image}; $_ } @{_searchItems($client, $tags->{search})} ],
			};
		},
	) );
=cut
}

sub postinitPlugin {
	my $class = shift;

	# if user has the Don't Stop The Music plugin enabled, register ourselves
	if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin') ) {
		Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_DEEZER_DSTM_SMART_RADIO', sub {
			my ($client, $cb) = @_;

			my $seedTracks = Slim::Plugin::DontStopTheMusic::Plugin->getMixableProperties($client, 50);

			# don't seed from radio stations - only do if we're playing from some track based source
			if ($seedTracks && ref $seedTracks && scalar @$seedTracks) {
				main::INFOLOG && $log->info("Creating Deezer Smart Radio from random items in current playlist");

				# get the most frequent artist in our list
				my %artists;

				foreach (@$seedTracks) {
					$artists{$_->{artist}}++;
				}

				# split "feat." etc. artists
				my @artists;
				foreach (keys %artists) {
					if ( my ($a1, $a2) = split(/\s*(?:\&|and|feat\S*)\s*/i, $_) ) {
						push @artists, $a1, $a2;
					}
				}

				unshift @artists, sort { $artists{$b} <=> $artists{$a} } keys %artists;

				dontStopTheMusic($client, $cb, @artists);
			}
			else {
				$cb->($client);
			}
		});

		Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_DEEZER_DSTM_FLOW', sub {
			$_[1]->($_[0], ['deezer://user/me/flow.dzr']);
		});
	}

	if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::OnlineLibrary::Plugin') ) {
		Slim::Plugin::OnlineLibrary::Plugin->addLibraryIconProvider('deezer', '/plugins/Deezer/html/logo.png');

		Slim::Plugin::OnlineLibrary::BrowseArtist->registerBrowseArtistItem( deezer => sub {
			my ( $client ) = @_;

			return {
				name => cstring($client, 'BROWSE_ON_SERVICE', 'Deezer'),
				type => 'link',
				icon => $class->_pluginDataFor('icon'),
				url  => \&browseArtistMenu,
			};
		} );
	}

	if ( Slim::Utils::PluginManager->isEnabled('Plugins::LastMix::Plugin') ) {
		eval {
			require Plugins::LastMix::Services;
		};

		if (!$@) {
			main::INFOLOG && $log->info("LastMix plugin is available - let's use it!");
			require Plugins::Deezer::LastMix;
			Plugins::LastMix::Services->registerHandler('Plugins::Deezer::LastMix', 'lossless');
		}
	}

	# if user has the Don't Stop The Music plugin enabled, register ourselves
	if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin') ) {
		Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_DEEZER_DSTM_SMART_RADIO', sub {
			my ($client, $cb) = @_;

			my $seedTracks = Slim::Plugin::DontStopTheMusic::Plugin->getMixableProperties($client, 50);

			# don't seed from radio stations - only do if we're playing from some track based source
			if ($seedTracks && ref $seedTracks && scalar @$seedTracks) {
				main::INFOLOG && $log->info("Creating Deezer Smart Radio from random items in current playlist");

				# get the most frequent artist in our list
				my %artists;

				foreach (@$seedTracks) {
					$artists{$_->{artist}}++;
				}

				# split "feat." etc. artists
				my @artists;
				foreach (keys %artists) {
					if ( my ($a1, $a2) = split(/\s*(?:\&|and|feat\S*)\s*/i, $_) ) {
						push @artists, $a1, $a2;
					}
				}

				unshift @artists, sort { $artists{$b} <=> $artists{$a} } keys %artists;

				dontStopTheMusic($client, $cb, @artists);
			}
			else {
				$cb->($client);
			}
		});

		Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_DEEZER_DSTM_FLOW', sub {
			$_[1]->($_[0], ['deezer://user/me/flow.dzr']);
		});
	}

}

sub onlineLibraryNeedsUpdate {
	my $class = shift;
	require Plugins::Deezer::Importer;
	return Plugins::Deezer::Importer->needsUpdate(@_);
}

sub getLibraryStats {
	require Plugins::Deezer::Importer;
	my $totals = Plugins::Deezer::Importer->getLibraryStats();
	return wantarray ? ('PLUGIN_DEEZER_NAME', $totals) : $totals;
}

sub handleFeed {
	my ($client, $cb, $args) = @_;

	if ( !Plugins::Deezer::API->getSomeUserId() ) {
		return $cb->({
			items => [{
				name => cstring($client, 'PLUGIN_DEEZER_REQUIRES_CREDENTIALS'),
				type => 'textarea',
			}]
		});
	}

	my $items = [ {
		name => cstring($client, 'HOME'),
		image => 'plugins/Deezer/html/home.png',
		type => 'link',
		url => \&Plugins::Deezer::Custom::getHome,
	}, {
		name => cstring($client, 'PLUGIN_DEEZER_FLOW'),
		image => 'plugins/Deezer/html/flow.png',
		play => 'deezer://user/me/flow.dzr',
		type => 'outline',
		items => [{
			name => cstring($client, 'PLUGIN_DEEZER_FLOW'),
			image => 'plugins/Deezer/html/flow.png',
			on_select => 'play',
			type => 'audio',
			url => 'deezer://user/me/flow.dzr',
			play => 'deezer://user/me/flow.dzr',
		},{
			name => cstring($client, 'GENRES'),
			image => 'html/images/genres.png',
			type => 'link',
			url => \&getFlow,
			passthrough => [{ mode => 'genres' }],
		},{
			name => cstring($client, 'PLUGIN_DEEZER_MOODS'),
			image => 'plugins/Deezer/html/moods_MTL_icon_celebration.png',
			type => 'link',
			url => \&getFlow,
			passthrough => [{ mode => 'moods' }],
		}],
	},{
		name => cstring($client, 'PLAYLISTS'),
		image => 'html/images/playlists.png',
		type => 'link',
		url => \&getFavorites,
		passthrough => [{ type => 'playlists' }],
	},{
		name => cstring($client, 'ALBUMS'),
		image => 'html/images/albums.png',
		type => 'link',
		url => \&getFavorites,
		passthrough => [{ type => 'albums' }],
	},{
		name => cstring($client, 'SONGS'),
		image => 'html/images/playall.png',
		type => 'link',
		url => \&getFavorites,
		passthrough => [{ type => 'tracks' }],
	},{
		name => cstring($client, 'ARTISTS'),
		image => 'html/images/artists.png',
		type => 'link',
		url => \&getFavorites,
		passthrough => [{ type => 'artists' }],
	# },{
		# name => cstring($client, 'PODCASTS'),
		# image => 'plugins/Deezer/html/podcast.png',
		# type => 'link',
		# url => \&getFavorites,
		# passthrough => [{ type => 'podcasts' }],
	},{
		name => cstring($client, 'GENRES'),
		image => 'html/images/genres.png',
		type => 'link',
		url => \&getGenres,
	},{
		name => cstring($client, 'PLUGIN_DEEZER_SMART_RADIO'),
		image => 'plugins/Deezer/html/smart_radio.png',
		type => 'link',
		url => \&getRadios,
	},{
		name => cstring($client, 'PLUGIN_DEEZER_CHART'),
		image => 'plugins/Deezer/html/charts.png',
		type => 'link',
		url => \&getCompound,
		passthrough => [{ path => 'chart' }],
	},{
		name => cstring($client, 'PLUGIN_PODCAST'),
		image => 'plugins/Deezer/html/rss.png',
		type  => 'link',
		url   => \&getPodcasts,
	}, {
		name  => cstring($client, 'SEARCH'),
		image => 'html/images/search.png',
		type => 'outline',
		items => [ {
			name => cstring($client, 'PLAYLISTS'),
			type  => 'search',
			url   => \&search,
			# image => 'html/images/playlists.png',
			passthrough => [{ type => 'playlist' }],
		},{
			name => cstring($client, 'ARTISTS'),
			type  => 'search',
			url   => \&search,
			# image => 'html/images/artists.png',
			passthrough => [{ type => 'artist' }],
		},{
			name => cstring($client, 'ALBUMS'),
			type  => 'search',
			url   => \&search,
			# image => 'html/images/albums.png',
			passthrough => [{ type => 'album' }],
		},{
			name => cstring($client, 'SONGS'),
			type  => 'search',
			url   => \&search,
			# image => 'html/images/playall.png',
			passthrough => [{ type => 'track' }],
		},{
			name => cstring($client, 'PLUGIN_PODCAST'),
			type  => 'search',
			url   => \&search,
			passthrough => [{ type => 'podcast' }],
		} ],
	} ];

	if ($client && keys %{$prefs->get('accounts') || {}} > 1) {
		push @$items, {
			name => cstring($client, 'PLUGIN_DEEZER_SELECT_ACCOUNT'),
			image => __PACKAGE__->_pluginDataFor('icon'),
			url => \&selectAccount,
		};
	}

	$cb->({ items => $items });
}

sub selectAccount {
	my ($client, $cb) = @_;
	my $userId = getAPIHandler($client)->userId;

	my $items = [ map {
		my $name = $_->{name} || $_->{email};
		$name = '[' . $name . ']' if $_->{id} == $userId;
		{
			name => $name,
			url => sub {
				my ($client, $cb2, $params, $args) = @_;

				$client->pluginData(api => 0);
				$prefs->client($client)->set('userId', $args->{id});

				$cb2->({ items => [{
					nextWindow => 'grandparent',
				}] });
			},
			passthrough => [{
				id => $_->{id}
			}],
			nextWindow => 'parent'
		}
	} sort values %{ $prefs->get('accounts') || {} } ];

	$cb->({ items => $items });
}

sub getFavorites {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->getFavorites(sub {
		my $items = shift;

		$items = [ map { _renderItem($client, $_, { addArtistToTitle => 1 }) } @$items ] if $items;

		$cb->( { items => $items } );
	}, $params->{type}, $args->{quantity} != 1 );
}

sub getArtistAlbums {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->artistAlbums(sub {
		my $items = _renderAlbums(@_);

		# the action can be there or in the sub-item as an itemActions
		$cb->( { items => $items } );
	}, $params->{id});
}

sub getArtistTopTracks {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->artistTopTracks(sub {
		my $items = _renderTracks(@_);
		$cb->( { items => $items } );
	}, $params->{id});
}

sub getArtistRelated {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->artistRelated(sub {
		my $items = _renderArtists($client, @_);
		$cb->( { items => $items } );
	}, $params->{id});
}

sub getAlbum {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->albumTracks(sub {
		my $items = _renderTracks(shift);
		$cb->( { items => $items } );
	}, $params->{id} );
}

sub getGenres {
	my ( $client, $callback ) = @_;

	getAPIHandler($client)->genres(sub {
		my $items = [ map { _renderGenreMusic($client, $_) } @{$_[0]} ];

		$callback->( { items => $items } );
	});
}

sub getFlow {
	my ( $client, $callback, $args, $params ) = @_;

	my $mode = $params->{mode} =~ /genre/ ? 'genre' : 'mood';
	my @categories = $mode eq 'genre' ?
					( 'pop', 'rap', 'rock', 'alternative', 'kpop', 'jazz', 'classical',
					  'chanson', 'reggae', 'latin', 'soul', 'variete', 'lofi', 'rnb',
					  'danceedm' ) :
					( 'motivation', 'party', 'chill', 'melancholy', 'you_and_me', 'focus');

	my $items = [ map {
		{
			name => cstring($client, 'PLUGIN_DEEZER_' . uc($_)),
			on_select => 'play',
			play => "deezer://$mode:" . $_ . '.flow',
			url => "deezer://$mode:" . $_ . '.flow',
			image => 'plugins/Deezer/html/' . $_ . '.png',
		}
	} @categories ];

	$callback->( { items => $items } );
}

sub getRadios {
	my ( $client, $callback ) = @_;

	getAPIHandler($client)->radios(sub {
		my $items = [ map { _renderItem($client, $_) } @{$_[0]} ];

		$callback->( { items => $items } );
	});
}

sub getGenreItems {
	my ( $client, $cb, $args, $params ) = @_;
	getAPIHandler($client)->genreByType(sub {

		my $items = [ map { _renderItem($client, $_, { addArtistToTitle => 1 } ) } @{$_[0]} ];

		$cb->( { items => $items } );
	}, $params->{id}, $params->{type} );
}

sub getCompound {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->compound(sub {
		my $items = _renderCompound($client, $_[0]);

		$cb->( {
			items => $items
		} );
	}, $params->{path} );
}

sub getPlaylist {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->playlistTracks(sub {
		my $items = _renderTracks($_[0], 1);
		$cb->( { items => $items } );
	}, $params->{id} );
}

sub getPodcasts {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->podcasts(sub {
		my $items = [ map { _renderGenrePodcast($_) } @{$_[0]} ];

		unshift @$items, {
			name => cstring($client, 'FAVORITES'),
			url => \&getFavorites,
			passthrough => [{ type => 'podcasts' }],
		};

		$cb->( { items => $items } );
	});
}

sub getPodcastEpisodes {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->podcastEpisodes(sub {
		my $items = _renderEpisodes($_[0]);

		$cb->( { items => $items } );
	}, $params->{id}, $params->{podcast} );

}

sub search {
	my ($client, $cb, $args, $params) = @_;

	$args->{search} ||= $params->{query};
	$args->{type} = $params->{type};
	$args->{strict} = $params->{strict} || 'off';

	getAPIHandler($client)->search(sub {
		my $items = shift;
		$items = [ map { _renderItem($client, $_) } @$items ] if $items;

		$cb->( { items => $items || [] } );
	}, $args);

}

sub _renderItem {
	my ($client, $item, $args) = @_;

	my $type = Plugins::Deezer::API->typeOfItem($item);

	if ($type eq 'track') {
		return _renderTrack($item, $args->{addArtistToTitle});
	}
	elsif ($type eq 'album') {
		return _renderAlbum($item, $args->{addArtistToTitle});
	}
	elsif ($type eq 'artist') {
		return _renderArtist($client, $item);
	}
	elsif ($type eq 'playlist') {
		return _renderPlaylist($item);
	}
	elsif ($type eq 'radio') {
		return _renderRadio($item);
	}
=comment
	elsif ($type eq 'genre') {
		return _renderGenre($client, $item, $args->{handler});
	}
=cut
	elsif ($type eq 'podcast') {
		return _renderPodcast($item);
	}
	elsif ($type eq 'episode') {
		return _renderEpisode($item, $args->{index});
	}
}

sub _renderPlaylists {
	my $results = shift;

	return [ map {
		_renderPlaylist($_)
	} @$results ];
}

sub _renderPlaylist {
	my $item = shift;

	return {
		name => $item->{title},
		line1 => $item->{title},
		line2 => $item->{user}->{name},
		favorites_url => 'deezer://playlist:' . $item->{id},
		favorites_type => 'playlist',
		play => 'deezer://playlist:' . $item->{id},
		type => 'playlist',
		itemActions => {
			info => {
				command   => ['deezer_info', 'items'],
				fixedParams => {
					type => 'playlists',
					id => $item->{id},
				},
			},
		},
		url => \&getPlaylist,
		image => Plugins::Deezer::API->getImageUrl($item, 'usePlaceholder'),
		passthrough => [ { id => $item->{id} } ],
	};
}

sub _renderAlbums {
	my ($results, $addArtistToTitle) = @_;

	return [ map {
		_renderAlbum($_, $addArtistToTitle);
	} @$results ];
}

sub _renderAlbum {
	my ($item, $addArtistToTitle) = @_;

	my $title = $item->{title};
	$title .= ' - ' . $item->{artist}->{name} if $addArtistToTitle;

	return {
		name => $title,
		line1 => $item->{title},
		line2 => $item->{artist}->{name},
		type => 'playlist',
		favorites_type => 'playlist',
		favorites_url => 'deezer://album:' . $item->{id},
		play => 'deezer://album:' . $item->{id},
		itemActions => {
			info => {
				command   => ['deezer_info', 'items'],
				fixedParams => {
					type => 'albums',
					id => $item->{id},
				},
			},
		},
		image => Plugins::Deezer::API->getImageUrl($item, 'usePlaceholder'),
		url => \&getAlbum,
		passthrough => [{ id => $item->{id}	}],
	};
}

sub _renderRadio {
	my $item = shift;

	return {
		name => $item->{title},
		line1 => $item->{description},
		on_select => 'play',
		play => "deezer://radio/$item->{id}/tracks.dzr",
		url => "deezer://radio/$item->{id}/tracks.dzr",
		image => Plugins::Deezer::API->getImageUrl($item),
	};
}

sub _renderTracks {
	my ($tracks, $addArtistToTitle) = @_;

	return [ map {
		_renderTrack($_, $addArtistToTitle);
	} @$tracks ];
}

sub _renderTrack {
	my ($item, $addArtistToTitle) = @_;

	my $title = $item->{title};
	$title .= ' - ' . $item->{artist}->{name} if $addArtistToTitle;
	my $url = "deezer://$item->{id}." . Plugins::Deezer::API::getFormat();

	return {
		name => $title,
		line1 => $item->{title},
		line2 => $item->{artist}->{name},
		on_select => 'play',
		url => $url,
		play => $url,
		playall => 1,
		image => $item->{cover},
		type => 'audio',
		itemActions => {
			info => {
				command   => ['deezer_info', 'items'],
				fixedParams => {
					type => 'tracks',
					id => $item->{id},
				},
			},
		},
	};
}

sub _renderPodcasts {
	my ($podcasts) = @_;

	return [ map {
		_renderPodcast($_);
	} @$podcasts ];
}

sub _renderPodcast {
	my ($item) = @_;

	return {
		name => $item->{title},
		line1 => $item->{title},
		line2 => $item->{description},
		# see comment on _renderAlbum and the issue about title that will
		# be missing as we'll use explodePlaylist. But if play is CODE, then
		# actions are ignored.
		favorites_url => 'deezer://podcast:' . $item->{id},
		play => 'deezer://podcast:' . $item->{id},
		type => 'playlist',
		itemActions => {
			info => {
				command   => ['deezer_info', 'items'],
				fixedParams => {
					type => 'podcasts',
					id => $item->{id},
				},
			},
		},
		url => \&getPodcastEpisodes,
		image => Plugins::Deezer::API->getImageUrl($item, 'usePlaceholder'),
		passthrough => [ {
			id => $item->{id},
			podcast => $item,
		} ],
	};
}

sub _renderEpisodes {
	my ($results) = @_;

	my $items = [];
	push @$items, _renderEpisode($results->[$_], $_) foreach (0...$#{$results});

	return $items;
}

sub _renderEpisode {
	my ($item, $index) = @_;

	# because of the strange way to recover episodes' streaming url, we need to memorize
	# the podcast id and the index in the podcast list of items. It's not great as it not
	# fool proof for long-term memorization of single episodes (e.g.) in favorites.
	# TODO: Try to find a better way to obtain the episode url or rescan the the whole
	# podcast/episodes until we found the episode's id. For now we'll store all the needed
	# information in the url. Memorizing the podcast id is not stricly necessary because
	# getting/episode/id will give us podcast id
	my $url = "deezerpodcast://$item->{podcast}->{id}/$item->{id}_$index";

	return {
		name => $item->{title},
		type => 'audio',
		on_select => 'play',
		playall => 1,
		play => $url,
		url => $url,
		image => $item->{cover},
		itemActions => {
			info => {
				command   => ['deezer_info', 'items'],
				fixedParams => {
					type => 'episodes',
					id => $item->{id},
				},
			},
		},
	};
}

sub _renderArtists {
	my ($client, $results) = @_;

	return [ map {
		_renderArtist($client, $_);
	} @$results ];
}

sub _renderArtist {
	my ($client, $item) = @_;

	my $image = Plugins::Deezer::API->getImageUrl($item, 'usePlaceholder');

	my $items = [ {
		name => cstring($client, 'PLUGIN_DEEZER_TOP_TRACKS'),
		favorites_url => 'deezer://artist:' . $item->{id},
		favorites_title => "$item->{name} - " . cstring($client, 'PLUGIN_DEEZER_TOP_TRACKS'),
		favorites_icon => $image,
		type => 'playlist',
		url => \&getArtistTopTracks,
		image => 'plugins/Deezer/html/charts.png',
		passthrough => [{ id => $item->{id} }],
	}, {
		type => 'link',
		name => cstring($client, 'ALBUMS'),
		url => \&getArtistAlbums,
		image => 'html/images/albums.png',
		passthrough => [{ id => $item->{id} }],
	}, {
		name => cstring($client, 'RADIO'),
		on_select => 'play',
		favorites_title => "$item->{name} - " . cstring($client, 'RADIO'),
		favorites_icon => $image,
		type => 'audio',
		play => "deezer://artist/$item->{id}/radio.dzr",
		url => "deezer://artist/$item->{id}/radio.dzr",
		image => 'plugins/Deezer/html/smart_radio.png',
	}, {
		type => 'link',
		name => cstring($client, 'PLUGIN_DEEZER_RELATED'),
		url => \&getArtistRelated,
		image => 'html/images/artists.png',
		passthrough => [{ id => $item->{id} }],
	} ];

	return {
		name => $item->{name} || $item->{title},
		type => 'outline',
		items => $items,
		itemActions => {
			info => {
				command   => ['deezer_info', 'items'],
				fixedParams => {
					type => 'artists',
					id => $item->{id},
				},
			},
		},
		image => $image,
	};
}

sub _renderCompound {
	my ($client, $item) = @_;

	my $items = [];

	push @$items, {
		name => cstring($client, 'PLAYLISTS'),
		items => _renderPlaylists($item->{playlists}),
		type  => 'outline',
		image => 'html/images/playlists.png',
	} if $item->{playlists};

	push @$items, {
		name => cstring($client, 'ARTISTS'),
		items => _renderArtists($client, $item->{artists}),
		type  => 'outline',
		image => 'html/images/artists.png',
	} if $item->{artists};

	push @$items, {
		name => cstring($client, 'ALBUMS'),
		items => _renderAlbums($item->{albums}),
		type  => 'outline',
		image => 'html/images/albums.png',
	} if $item->{albums};

	push @$items, {
		name => cstring($client, 'SONGS'),
		items => _renderTracks($item->{tracks}),
		type  => 'outline',
		image => 'html/images/playall.png',
	} if $item->{tracks};

	push @$items, {
		name => cstring($client, 'PLUGIN_PODCAST'),
		items => _renderPodcasts($item->{podcasts}),
		type  => 'outline',
		image => 'plugins/Deezer/html/rss.png',
	} if $item->{podcasts};

	return $items;
}

sub _renderGenreMusic {
	my ($client, $item, $renderer) = @_;

	my $items = [ {
		name => cstring($client, 'ARTISTS'),
		type  => 'link',
		url   => \&getGenreItems,
		image => 'html/images/artists.png',
		passthrough => [ { id => $item->{id}, type => 'artists' } ],
	}, {
		name => cstring($client, 'RADIO'),
		type  => 'link',
		url   => \&getGenreItems,
		image => 'plugins/Deezer/html/smart_radio.png',
		passthrough => [ { id => $item->{id}, type => 'radios' } ],
	} ];

	return {
		name => $item->{name},
		type => 'outline',
		items => $items,
		image => Plugins::Deezer::API->getImageUrl($item, 'usePlaceholder', 'genre'),
		passthrough => [ { id => $item->{id} } ],
	};
}

sub _renderGenrePodcast {
	my ($item) = @_;

	return {
		name => $item->{name},
		url => \&getGenreItems,
		# there is no usable icon/image
		passthrough => [ {
			id => $item->{id},
			type => 'podcasts',
		} ],
	};
}

sub getAPIHandler {
	my ($client) = @_;

	my $api;

	if (ref $client) {
		$api = $client->pluginData('api');

		if ( !$api ) {
			# if there's no account assigned to the player, just pick one
			if ( !$prefs->client($client)->get('userId') ) {
				my $userId = Plugins::Deezer::API->getSomeUserId();
				$prefs->client($client)->set('userId', $userId) if $userId;
			}

			$api = $client->pluginData( api => Plugins::Deezer::API::Async->new({
				client => $client
			}) );
		}
	}
	else {
		$api = Plugins::Deezer::API::Async->new({
			userId => Plugins::Deezer::API->getSomeUserId()
		});
	}

	logBacktrace("Failed to get a Deezer API instance: $client") unless $api;

	return $api;
}

sub trackInfoMenu {
	my ($client, $url, $track, $remoteMeta) = @_;

	my $artist = $track->remote ? $remoteMeta->{artist} : $track->artistName;
	my $album  = $track->remote ? $remoteMeta->{album} : ( $track->album ? $track->album->name : undef );
	my $title  = $track->remote ? $remoteMeta->{title} : $track->title;

=comment
	my $query .= 'artist:' . "\"$artist\" " if $artist;
	$query .= 'album:' . "\"$album\" " if $album;
	$query .= 'track:' . "\"$title\"" if $title;
	main::INFOLOG && $log->is_info && $log->info("Getting info with query $query");
=cut
	my $search = cstring($client, 'SEARCH');
	my $items = [];

	push @$items, {
		name => "$search " . cstring($client, 'ARTISTS') . " '$artist'",
		type => 'link',
		url => \&search,
		image => 'html/images/artists.png',
		passthrough => [ {
			type => 'artist',
			query => $artist,
			strict => 'on',
		} ],
	} if $artist;

	push @$items, {
		name => "$search " . cstring($client, 'ALBUMS') . " '$album'",
		type => 'link',
		url => \&search,
		image => 'html/images/albums.png',
		passthrough => [ {
			type => 'album',
			query => $album,
			strict => 'on',
		} ],
	} if $album;

	push @$items, {
		name => "$search " . cstring($client, 'SONGS') . " '$title'",
		type => 'link',
		url => \&search,
		image => 'html/images/playall.png',
		passthrough => [ {
			type => 'track',
			query => $title,
			strict => 'on',
		} ],
	} if $title;

	return {
		type => 'outlink',
		items => $items,
		name => cstring($client, 'PLUGIN_DEEZER_ON_DEEZER'),
	};
}

sub albumInfoMenu {
	my ($client, $url, $album, $remoteMeta) = @_;

	my @artists;
	push @artists, $album->artistsForRoles('ARTIST'), $album->artistsForRoles('ALBUMARTIST');
	my $artist = $artists[0]->name;
	my $album  = ($remoteMeta && $remoteMeta->{album}) || ($album && $album->title);

	my $query = 'album:' . "\"$album\" ";
	$query .= 'artist:' . "\"$artist\" " if $artist;
	main::INFOLOG && $log->is_info && $log->info("Getting info with query $query");

	return {
		type      => 'link',
		name      => cstring($client, 'PLUGIN_DEEZER_ON_DEEZER'),
		url       => \&search,
		# image 	  => __PACKAGE__->_pluginDataFor('icon'),
		passthrough => [ {
			query => $query,
			strict => 'on',
		} ],
	};
}

sub artistInfoMenu {
	my ($client, $url, $artist, $remoteMeta) = @_;

	my $artist  = ($remoteMeta && $remoteMeta->{artist}) || ($artist && $artist->name);
	my $query = 'artist:' . "\"$artist\" ";
	main::INFOLOG && $log->is_info && $log->info("Getting info with query $query");

	return {
		type      => 'link',
		name      => cstring($client, 'PLUGIN_DEEZER_ON_DEEZER'),
		url       => \&search,
		# image 	  => __PACKAGE__->_pluginDataFor('icon'),
		passthrough => [ {
			query => $query,
			strict => 'on',
		} ],
	};
}

sub browseArtistMenu {
	my ($client, $cb, $args, $params) = @_;

	my $empty = [{
		type  => 'text',
		title => cstring($client, 'EMPTY'),
	}];

	my $artistId = $args->{artist_id} || $args->{artist_id};

	if ( defined($artistId) && $artistId =~ /^\d+$/ && (my $artistObj = Slim::Schema->resultset("Contributor")->find($artistId))) {

		if (my ($extId) = grep /deezer:artist:(\d+)/, @{$artistObj->extIds}) {
			my ($id) = $extId =~ /deezer:artist:(\d+)/;

			getAPIHandler($client)->artist(sub {
				my $items = _renderArtist( $client, $_[0] ) if $_[0];
				$cb->($items || $empty);
			}, $id );

		} else {

			search($client, sub {
					$cb->($_[0]->{items} || $empty);
				}, $args,
				{
					type => 'artist',
					query => $artistObj->name,
					strict => 'on',
				}
			);

		}
	} else {
		$cb->( $empty );
	}
}

sub menuInfoWeb {
	my $request = shift;

	# be careful that type must be artistS|albumS|playlistS|trackS
	my $type = $request->getParam('type');
	my $id = $request->getParam('id');

#$log->error("IN INFOWEB !!!!!!!!!!!!!!!!!!!!! ", Data::Dump::dump($request));
	$request->addParam('_index', 0);
	$request->addParam('_quantity', 10);

	# we can't get the response live, we must be called back by cliQuery to
	# call it back ourselves
	Slim::Control::XMLBrowser::cliQuery('deezer_info', sub {
		my ($client, $cb, $args) = @_;

		my $api = getAPIHandler($client);

		$api->getFavorites( sub {
			my $favorites = shift;

			my $action = (grep { $_->{id} == $id && ($type =~ /$_->{type}/ || !$_->{type}) } @$favorites) ? 'remove' : 'add';
			my $title = $action eq 'remove' ? cstring($client, 'PLUGIN_FAVORITES_REMOVE') : cstring($client, 'PLUGIN_FAVORITES_SAVE');

			my $item;

			if ($request->getParam('menu')) {
				$item = {
					type => 'link',
					name => $title,
					isContextMenu => 1,
					refresh => 1,
					jive => {
						actions => {
							go => {
								player => 0,
								cmd    => [ 'deezer_info', 'jive' ],
									params => {
									type => $type,
									id => $id,
									action => $action,
								},
							}
						},
						nextWindow => 'parent'
					},
				};
			} else {
				$item = {
					type => 'link',
					name => $title,
					url => sub {
						my ($client, $ucb) = @_;
						$api->updateFavorite( sub {
							$ucb->({
								items => [{
									type => 'text',
									name => cstring($client, 'COMPLETE'),
								}],
							});
						}, $action, $type, $id );
					},
				};
			}

			my $method;

			if ( $type =~ /tracks/ ) {
				$method = \&_menuTrackInfo;
			} elsif ( $type =~ /albums/ ) {
				$method = \&_menuAlbumInfo;
			} elsif ( $type =~ /artists/ ) {
				$method = \&_menuArtistInfo;
			} elsif ( $type =~ /playlists/ ) {
				$method = \&_menuPlaylistInfo;
			} elsif ( $type =~ /podcasts/ ) {
				$method = \&_menuPodcastInfo;
			} elsif ( $type =~ /episodes/ ) {
				$method = \&_menuEpisodeInfo;
			}

			$method->( $api, $item, sub {
				my ($items, $icon) = @_;
#$log->error("THIS IS WHAT WE RETURN TO CLIQUERY", Data::Dump::dump($items));
				$cb->( {
					type  => 'opml',
					#menuComplete => 1,
					image => $icon,
					items => $items,
				} );
			}, $args->{params});

		}, $type );

	}, $request );
}

sub menuInfoJive {
	my $request = shift;

	my $type = $request->getParam('type');
	my $id = $request->getParam('id');
	my $api = getAPIHandler($request->client);
	my $action = $request->getParam('action');

	$api->updateFavorite( sub { }, $action, $type, $id );
}

sub menuBrowse {
	my $request = shift;

	my $client = $request->client;

	my $itemId = $request->getParam('item_id');
	my $type = $request->getParam('type');
	my $id = $request->getParam('id');

	$request->addParam('_index', 0);
	# TODO: why do we need to set that
	$request->addParam('_quantity', 200);

	main::INFOLOG && $log->is_info && $log->info("Browsing for item_id:$itemId or type:$type:$id");

	# if we are descending, no need to search, just get our root
	if ( defined $itemId ) {
		my ($key) = $itemId =~ /([^\.]+)/;
		my $cached = ${$rootFeeds{$key}};
#$log->error("usin cached feed ==========================", Data::Dump::dump($cached));
		Slim::Control::XMLBrowser::cliQuery('deezer_browse', $cached, $request);
		return;
	}

	# this key will prefix each action's hierarchy that JSON will sent us which
	# allows us to find our back our root feed. During drill-down, that prefix
	# is removed and XMLBrowser descends the feed.
	# ideally, we would like to not have to do that but that means we leave some
	# breadcrums *before* we arrive here, in the _renderXXX familiy but I don't
	# know how so we have to build our own "fake" dispatch just for that
	# we only need to do that when we have to redescend further that hierarchy,
	# not when it's one shot
	my $key = $client->id =~ s/://gr;
	$request->addParam('item_id', $key);

	Slim::Control::XMLBrowser::cliQuery('deezer_browse', sub {
		my ($client, $cb, $args) = @_;

		if ( $type =~ /album/ ) {

			getAlbum($client, sub {
				my $feed = $_[0];
				$rootFeeds{$key} = \$feed;
				$cb->($feed);
			}, $args, { id => $id } );

		} elsif ( $type =~ /artist/ ) {

			getAPIHandler($client)->artist(sub {
				my $feed = _renderArtist( $client, $_[0] ) if $_[0];
				$rootFeeds{$key} = \$feed;
				# no need to add any action, the root 'deezer_browse' is memorized and cliQuery
				# will provide us with item_id hierarchy. All we need is to know where our root
				# by prefixing item_id with a min 8-digits length hexa string
				$cb->($feed);
			}, $id );

		} elsif ( $type =~ /playlist/ ) {

			# we don't need to memorize the feed as we won't redescend into it
			getPlaylist($client, $cb, $args, { id => $id } );

		} elsif ( $type =~ /track/ ) {

			# track must be in cache, no memorizing
			my $cache = Slim::Utils::Cache->new;
			my $track = _renderTrack($cache->get('deezer_meta_' . $id));
			$cb->([$track]);

		} elsif ( $type =~ /podcast/ ) {

			# we need to re-acquire the podcast itself
			getAPIHandler($client)->podcast(sub {
				my $podcast = shift;
				getPodcastEpisodes($client, $cb, $args, {
					id => $id,
					podcast => $podcast,
				} );
			}, $id );

		} elsif ( $type =~ /episode/ ) {

			# track must be in cache, no memorizing
			my $cache = Slim::Utils::Cache->new;
			my $episode = _renderEpisode($cache->get('deezer_episode_meta_' . $id));
			$cb->([$episode]);

		}
	}, $request );
}

sub _menuTrackInfo {
	my ($api, $item, $cb, $params) = @_;

	my $cache = Slim::Utils::Cache->new;
	my $id = $params->{id};
	my $items = [];

	# if we are here, the metadata of the track is cached
	my $track = $cache->get("deezer_meta_$id");
	$log->error("metadata not cached for $id") && return [] unless $track;

	# play/add/add_next options except for skins that don't want it
	push @$items, (
		_menuPlay($api->client, 'track', $track->{id}, $params->{menu}),
		_menuAdd($api->client, 'track', $track->{id}, 'insert', 'PLAY_NEXT', $params->{menu}),
		_menuAdd($api->client, 'track', $track->{id}, 'add', 'ADD_TO_END', $params->{menu})
	) if $params->{useContextMenu} || $params->{feedMode};

	push @$items, ( $item, {
		type => 'link',
		name =>  $track->{album}->{title},
		label => 'ALBUM',
		itemActions => {
			items => {
				command     => ['deezer_browse', 'items'],
				fixedParams => { type => 'album', id => $track->{album}->{id} },
			},
		},
	}, {
		type => 'link',
		name =>  $track->{artist}->{name},
		label => 'ARTIST',
		itemActions => {
			items => {
				command     => ['deezer_browse', 'items'],
				fixedParams => { type => 'artist', id => $track->{artist}->{id} },
			},
		},
	}, {
		type => 'text',
		name => sprintf('%s:%02s', int($track->{duration} / 60), $track->{duration} % 60),
		label => 'LENGTH',
	}, {
		type  => 'text',
		name  => $track->{link},
		label => 'URL',
		parseURLs => 1
	} );

	$cb->($items, $track->{cover});
}

sub _menuAdd {
	my ($client, $type, $id, $cmd, $title, $menuMode) = @_;

	my $actions = {
			items => {
				command     => [ 'deezer_browse', 'playlist', $cmd ],
				fixedParams => { type => $type, id => $id },
			},
		};

	$actions->{'play'} = $actions->{'items'};
	$actions->{'add'}  = $actions->{'items'};

	return {
		itemActions => $actions,
		nextWindow  => 'parent',
		type        => $menuMode ? 'text' : 'link',
		playcontrol => $cmd,
		name        => cstring($client, $title),
	};
}

sub _menuPlay {
	my ($client, $type, $id, $menuMode) = @_;

	my $actions = {
			items => {
				command     => [ 'deezer_browse', 'playlist', 'load' ],
				fixedParams => { type => $type, id => $id },
			},
		};

	$actions->{'play'} = $actions->{'items'};

	return {
		itemActions => $actions,
		nextWindow  => 'nowPlaying',
		type        => $menuMode ? 'text' : 'link',
		playcontrol => 'play',
		name        => cstring($client, 'PLAY'),
	};
}

sub _menuAlbumInfo {
	my ($api, $item, $cb, $params) = @_;

	my $id = $params->{id};

	$api->album( sub {
		my $album = shift;

		my $items = [];

		# play/add/add_next options except for skins that don't want it
		push @$items, (
			_menuPlay($api->client, 'album', $id, $params->{menu}),
			_menuAdd($api->client, 'album', $id, 'insert', 'PLAY_NEXT', $params->{menu}),
			_menuAdd($api->client, 'album', $id, 'add', 'ADD_TO_END', $params->{menu})
		) if $params->{useContextMenu} || $params->{feedMode};

		push @$items, ( $item, {
			type => 'playlist',
			name =>  $album->{artist}->{name},
			label => 'ARTIST',
			itemActions => {
				items => {
					command     => ['deezer_browse', 'items'],
					fixedParams => { type => 'artist', id => $album->{artist}->{id} },
				},
			},
		}, {
			type => 'text',
			name => $album->{nb_tracks} || 0,
			label => 'TRACK_NUMBER',
		}, {
			type => 'text',
			name => substr($album->{release_date}, 0, 4),
			label => 'YEAR',
		}, {
			type => 'text',
			name => $album->{genres}->{data}->[0]->{name},
			label => 'GENRE',
		}, {
			type => 'text',
			name => sprintf('%s:%02s', int($album->{duration} / 60), $album->{duration} % 60),
			label => 'LENGTH',
		}, {
			type  => 'text',
			name  => $album->{link},
			label => 'URL',
			parseURLs => 1
		} );

		my $icon = Plugins::Deezer::API->getImageUrl($album, 'usePlaceholder');
		$cb->($items, $icon);

	}, $id );
}

sub _menuArtistInfo {
	my ($api, $item, $cb, $params) = @_;

	my $id = $params->{id};

	$api->artist( sub {
		my $artist = shift;

		my $items = [ $item, {
			type => 'link',
			name =>  $artist->{name},
			url => 'N/A',
			label => 'ARTIST',
			itemActions => {
				items => {
					command     => ['deezer_browse', 'items'],
					fixedParams => { type => 'artist', id => $artist->{id} },
				},
			},
		}, {
			type => 'text',
			name => $artist->{nb_album},
			label => 'ALBUM',
		}, {
			type  => 'text',
			name  => $artist->{link},
			label => 'URL',
			parseURLs => 1
		} ];

		my $icon = Plugins::Deezer::API->getImageUrl($artist, 'usePlaceholder');
		$cb->($items, $icon);

	}, $id );
}

sub _menuPlaylistInfo {
	my ($api, $item, $cb, $params) = @_;

	my $id = $params->{id};

	$api->playlist( sub {
		my $playlist = shift;

		my $items = [];

		# play/add/add_next options except for skins that don't want it
		push @$items, (
			_menuPlay($api->client, 'playlist', $id, $params->{menu}),
			_menuAdd($api->client, 'playlist', $id, 'insert', 'PLAY_NEXT', $params->{menu}),
			_menuAdd($api->client, 'playlist', $id, 'add', 'ADD_TO_END', $params->{menu})
		) if $params->{useContextMenu} || $params->{feedMode};

		push @$items, ( $item, {
			type => 'text',
			name =>  $playlist->{creator}->{name},
			label => 'ARTIST',
		}, {
			type => 'text',
			name =>  $playlist->{title},
			label => 'ALBUM',
		}, {
			type => 'text',
			name => $playlist->{nb_tracks} || 0,
			label => 'TRACK_NUMBER',
		}, {
			type => 'text',
			name => substr($playlist->{creation_date}, 0, 4),
			label => 'YEAR',
		}, {
			type => 'text',
			name => sprintf('%02s:%02s:%02s', int($playlist->{duration} / 3600), int(($playlist->{duration} % 3600)/ 60), $playlist->{duration} % 60),
			label => 'LENGTH',
		}, {
			type  => 'text',
			name  => $playlist->{link},
			label => 'URL',
			parseURLs => 1
		} );

		my $icon = Plugins::Deezer::API->getImageUrl($playlist, 'usePlaceholder');
		$cb->($items, $icon);

	}, $id );
}

sub _menuPodcastInfo {
	my ($api, $item, $cb, $params) = @_;

	my $id = $params->{id};

	$api->podcast( sub {
		my $podcast = shift;

		my $items = [];

		# play/add/add_next options except for skins that don't want it
		push @$items, (
			_menuPlay($api->client, 'podcast', $id, $params->{menu}),
			_menuAdd($api->client, 'podcast', $id, 'insert', 'PLAY_NEXT', $params->{menu}),
			_menuAdd($api->client, 'podcast', $id, 'add', 'ADD_TO_END', $params->{menu})
		) if $params->{useContextMenu} || $params->{feedMode};

		push @$items, ( $item, {
			# put that one as an "album" otherwise control icons won't appear
			type => 'text',
			name =>  $podcast->{title},
			label => 'ALBUM',
		}, {
			type  => 'text',
			name  => $podcast->{link},
			label => 'URL',
			parseURLs => 1
		}, {
			type => 'text',
			name => $podcast->{description},
			label => 'COMMENT',
			parseURLs => 1
		} );

		my $icon = Plugins::Deezer::API->getImageUrl($podcast, 'usePlaceholder');
		$cb->($items, $icon);

	}, $id );
}

sub _menuEpisodeInfo {
	my ($api, $item, $cb, $params) = @_;

	my $cache = Slim::Utils::Cache->new;
	my $id = $params->{id};

	# unlike tracks, we miss some information when drilling down on podcast episodes
	$api->episode( sub {
		my $episode = shift;

		my $items = [];

		# play/add/add_next options except for skins that don't want it
		push @$items, (
			_menuPlay($api->client, 'episode', $id, $params->{menu}),
			_menuAdd($api->client, 'episode', $id, 'insert', 'PLAY_NEXT', $params->{menu}),
			_menuAdd($api->client, 'episode', $id, 'add', 'ADD_TO_END', $params->{menu})
		) if $params->{useContextMenu} || $params->{feedMode};

		push @$items, ( $item, {
			# put that one as an "album" otherwise control icons won't appear
			type => 'text',
			name =>  $episode->{podcast}->{title},
			label => 'ALBUM',
		}, {
			type => 'text',
			name =>  $episode->{title},
			label => 'TITLE',
		}, {
			type => 'text',
			name => sprintf('%02s:%02s:%02s', int($episode->{duration} / 3600), int(($episode->{duration} % 3600)/ 60), $episode->{duration} % 60),
			label => 'LENGTH',
		}, {
			type => 'text',
			label => 'MODTIME',
			name => $episode->{date},
		}, {
			type  => 'text',
			name  => $episode->{link},
			label => 'URL',
			parseURLs => 1
		}, {
			type => 'text',
			name => $episode->{comment},
			label => 'COMMENT',
			parseURLs => 1
		} );

		my $icon = Plugins::Deezer::API->getImageUrl($episode, 'usePlaceholder');
		$cb->($items, $icon);

	}, $id );
}

sub dontStopTheMusic {
	my $client  = shift;
	my $cb      = shift;
	my $nextArtist = shift;
	my @artists = @_;

	if ($nextArtist) {
		getAPIHandler($client)->search(sub {
			my $artists = shift || [];

			my ($track) = map {
				"deezer://artist/$_->{id}/radio.dzr"
			} grep {
				$_->{radio}
			} @$artists;

			if ($track) {
				$cb->($client, [$track]);
			}
			else {
				dontStopTheMusic($client, $cb, @artists);
			}
		},{
			search => $nextArtist,
			type => 'artist',
			# strict => 'off'
		});
	}
	else {
		main::INFOLOG && $log->is_info && $log->info("No matching Smart Radio found for current playlist!");
		$cb->($client);
	}
}

sub dontStopTheMusic {
	my $client  = shift;
	my $cb      = shift;
	my $nextArtist = shift;
	my @artists = @_;

	if ($nextArtist) {
		getAPIHandler($client)->search(sub {
			my $artists = shift || [];

			my ($track) = map {
				"deezer://artist/$_->{id}/radio.dzr"
			} grep {
				$_->{radio}
			} @$artists;

			if ($track) {
				$cb->($client, [$track]);
			}
			else {
				dontStopTheMusic($client, $cb, @artists);
			}
		},{
			search => $nextArtist,
			type => 'artist',
			# strict => 'off'
		});
	}
	else {
		main::INFOLOG && $log->is_info && $log->info("No matching Smart Radio found for current playlist!");
		$cb->($client);
	}
}


1;