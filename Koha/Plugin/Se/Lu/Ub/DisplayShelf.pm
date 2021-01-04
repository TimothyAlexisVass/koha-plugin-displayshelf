package Koha::Plugin::Se::Lu::Ub::DisplayShelf;
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
use Modern::Perl;
use utf8;
use base qw(Koha::Plugins::Base);
use CGI;
use Template;
use LWP::Simple qw(head);

use C4::Koha qw(NormalizeISBN);

use Koha::Biblios;
use Koha::News;
use Koha::NewsItem;
use Koha::Util::Normalize qw(ISBN);
use Koha::Virtualshelves;
use Koha::Config::SysPrefs;

our $VERSION = 1.0;
our $metadata = {
    name            => 'Display shelf',
    author          => 'Lunds University Library',
    description     => 'Koha plugin for displaying Virtualshelves list as a carousel style wrap-around slideshow. Includes cover images from syndetics.com.',
    date_authored   => '2020-12-09',
    date_updated    => '2020-12-10',
    minimum_version => '20.05.03',
    maximum_version => undef,
    version         => $VERSION,
};

sub new {
    my ($class, $args) = @_;
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;
    my $self = $class->SUPER::new($args);

    return $self;
}

sub tool {
    my ($self, $args) = @_;
    my $cgi = $self->{'cgi'};

    my @newsRaw = Koha::News->search();
    my @shelves = Koha::Virtualshelves->search();
    my @numbers;
    # A news block will exist for each language
    my @languages = split(',', Koha::Config::SysPrefs->find({ variable => "opaclanguages"})->value);
    foreach my $newsitem (@newsRaw) {
        my @temp = split /_/, $newsitem->title;
        if($temp[0] eq "DisplayShelf" and $temp[2] eq $languages[0]) {
            push @numbers, $temp[1];
        }
    }

    if ($cgi->param("action")) {
        my $selectedShelf = $cgi->param('selectedShelf');
        # number can either be 'add', 'remove_?' or '?' where ? is the number of the DisplayShelf to be removed or replaced.
        my $number = $cgi->param('number');

        $self->generate($selectedShelf, $number);
        $self->go_home();
    }
    else {
        my $template = $self->get_template({ file => 'tool.tt' });

        $template->param(
            numbers     => \@numbers,
            shelves     => \@shelves,
        );
        print $cgi->header(-type => 'text/html',-charset => 'utf-8');
        print $template->output();
    }
}

sub generate {
    my ($self, $selectedShelf, $number) = @_;
    my $class = $self->{class};
    my @languages = split(',', Koha::Config::SysPrefs->find({ variable => "opaclanguages"})->value);
    if ($number < 0) {
        $number = -$number;
        Koha::News->search({ title => {'like' => "DisplayShelf_$number%"} })->delete;

        my $start = $number + 1;
        foreach my $language (@languages) {
            my $newTitle;
            $number = $start;
            my $news = Koha::News->find({ title => "DisplayShelf_$number\_$language" });
            if ($news) {
                while ($news) {
                    $news->update({title => "DisplayShelf_" . ($number - 1) . "_$language"});
                    $number++;
                    $news = Koha::News->find({ title => "DisplayShelf_$number\_$language" });
                }
            }
            else {
                break;
            }
        }
        return;
    }
    my $shelf = Koha::Virtualshelves->find({shelfnumber => $selectedShelf});

    my $contents = $shelf->get_contents;
    my @items;
    while(my $content = $contents->next) {
        push @items, $content->biblionumber;
    }

    my @images;
    my $shelfname = $shelf->shelfname;
    $shelfname =~ s/[^a-zA-Z0-9]/_/g;

    foreach my $biblionumber (@items) {
        my $biblio = Koha::Biblios->find({ biblionumber => $biblionumber });
        next if ! $biblio;
        my $record = $biblio->metadata->record;
        next if ! $record;
        my $title = $biblio->title;
        $title =~ s/[,:\/\s]+$//;

        my $url = $self->getCoverImage($biblionumber, $record);
        if ($url) {
            push @images, {url => $url, title => $title, biblionumber => $biblionumber};
        }
        else {
            warn "[$class] There was no image found for biblionumber $biblionumber : \" $title \"\n";
        }
    }

    unless (@images) {
        warn "[$class] No images were found for virtualshelf '$shelfname' (id: $selectedShelf).\n";
        return;
    }

    my $template = Template->new(INCLUDE_PATH => $self->get_plugin_dir);
    my $data;

    $template->process(
        'slideshow.tt',
        { shelfname => $shelfname, documents => \@images },
        \$data,
        { binmode => ':utf8' }
    ) || warn "Unable to generate Display shelf, " . $template->error();

    foreach my $language (@languages) {
        my $news = Koha::News->find({ title => "DisplayShelf_$number\_$language" });
        if ($news) {
            $news->update({content => $data});
        }
        else {
            Koha::NewsItem->new({
                lang    => "OpacMainUserBlock_$language",
                title   => "DisplayShelf_$number\_$language",
                content => "$data",
            })->store;
        }
    }
}

sub getCoverImage {
    my ($self, $biblionumber, $record) = @_;
    return if ! $record;
    my $marcflavour = Koha::Config::SysPrefs->find( {variable => "marcflavour"} )->value;
    my @isbns;
    if ($marcflavour eq 'MARC21') {
        @isbns = $record->field('020');
    }
    elsif ($marcflavour eq 'UNIMARC') {
        @isbns = $record->field('010');
    }

    # Get thumbnail from Syndetics
    my $isbn;
    my $url;
    my $useragent = LWP::UserAgent->new;
    foreach my $field (@isbns) {
        $isbn = ISBN($field->subfield('a'));
        next if ! $isbn;

        $url = "https://www.syndetics.com/index.aspx?isbn=$isbn/LC.GIF&client=lundulib";

        my $http_request = HTTP::Request->new(GET => $url);
        my $http_response = $useragent->request($http_request);
        next unless $http_response->is_success;

        my $content_type = $http_response->header('content_type');

        if ($content_type =~ /^image/) {
            return $url;
        }
    }

    return;
}

sub uninstall() {
    Koha::News->search({ title => {'like' => "DisplayShelf%"} })->delete;
}

1;
