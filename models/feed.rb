class Feed
  require 'osub'
  require 'opub'
  require 'nokogiri'

  include MongoMapper::Document

  # Feed url (and an indicator that it is local)
  key :remote_url, String

  # OStatus subscriber information
  key :verify_token, String
  key :secret, String

  # For both pubs and subs, it needs to know
  # what hubs are communicating with it
  key :hubs, Array

  belongs_to :author
  many :updates
  one :user

  after_create :default_hubs

  def populate
    # TODO: More entropy would be nice
    self.verify_token = Digest::MD5.hexdigest(rand.to_s)
    self.secret = Digest::MD5.hexdigest(rand.to_s)

    f = OStatus::Feed.from_url(url)

    avatar_url = f.icon
    if avatar_url == nil
      avatar_url = f.logo
    end

    a = f.author

    self.author = Author.create(:name => a.portable_contacts.display_name,
                                :username => a.name,
                                :email => a.email,
                                :remote_url => a.uri,
                                :image_url => avatar_url)

    self.hubs = f.hubs

    populate_entries(f.entries)

    save
  end

  def populate_entries(os_entries)
    os_entries.each do |entry|
      u = Update.first(:url => entry.url)
      if u.nil?
        u = Update.create(:author => self.author,
                          :created_at => entry.published,
                          :url => entry.url,
                          :updated_at => entry.updated)
        self.updates << u
        save
      end

      # Strip HTML
      u.text = Nokogiri::HTML::Document.parse(entry.content).text
      u.save
    end
  end

  # Pings hub
  # needs absolute url for feed to give to hub for callback
  def ping_hubs(feed_url)
    OPub::Publisher.new(feed_url, hubs).ping_hubs
  end

  def local?
    url.start_with?("/")
  end

  def url
    if remote_url.nil?
      "/feeds/#{id}"
    else
      remote_url
    end
  end

  def update_entries(atom_xml, callback_url, feed_url, signature)
    sub = OSub::Subscription.new(callback_url, feed_url, self.secret)

    if sub.verify_content(atom_xml, signature)
      os_feed = OStatus::Feed.from_string(atom_xml)
      # TODO:
      # Update author if necessary

      # Update entries
      populate_entries(os_feed.entries)
    end
  end

  # Set default hubs
  def default_hubs
    self.hubs << "http://pubsubhubbub.appspot.com/publish"
    save
  end

  # create atom feed
  # need base_uri since urls outgoing should be absolute
  def atom(base_uri)
    # Create the OStatus::PortableContacts object
    poco = OStatus::PortableContacts.new(:id => author.id,
                                         :display_name => author.name,
                                         :preferred_username => author.username)

    # Create the OStatus::Author object
    os_auth = OStatus::Author.new(:name => author.username,
                                 :email => author.email,
                                 :uri => author.website,
                                 :portable_contacts => poco)

    # Gather entries as OStatus::Entry objects
    entries = updates.to_a.sort{|a, b| b.created_at <=> a.created_at}.map do |update|
      OStatus::Entry.new(:title => update.text,
                         :content => update.text,
                         :updated => update.updated_at,
                         :published => update.created_at,
                         :id => update.id,
                         :link => { :href => ("#{base_uri}updates/#{update.id.to_s}")})
    end

    # Create a Feed representation which we can generate
    # the Atom feed and send out.
    feed = OStatus::Feed.from_data("#{base_uri}feeds/#{id}.atom",
                                   :title => "#{author.username}'s Updates",
                                   :id => "#{base_uri}feeds/#{id}.atom",
                                   :author => os_auth,
                                   :entries => entries,
                                   :links => {
                                     :hub => [{:href => hubs.first}]
                                   })
    feed.atom
  end
end
