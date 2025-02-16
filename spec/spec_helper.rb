require 'rubygems'
require 'webmock/rspec'
require 'stripe_mock_patch'
require "alaveteli_features/spec_helpers"
require 'strip_attributes/matchers'

require_relative 'spec_coverage' if ENV['COVERAGE'] == 'local' || ENV['CI']

# This file is copied to spec/ when you run 'rails generate rspec:install'
ENV["RAILS_ENV"] ||= 'test'
require File.expand_path("../../config/environment", __FILE__)
require 'rspec/rails'

# Requires supporting ruby files with custom matchers and macros, etc,
# in spec/support/ and its subdirectories.
Dir[Rails.root.join("spec/support/**/*.rb")].each { |f| require f }

load "#{Rails.root}/db/seeds.rb"
# Use test-specific translations
locale_path = File.join(File.dirname(__FILE__), 'fixtures', 'locale')
repos = [ FastGettext::TranslationRepository.build('app',
                                                   :path => locale_path,
                                                   :type => :po) ]
AlaveteliLocalization.set_default_text_domain('app', repos)

RSpec.configure do |config|
  # ## Mock Framework
  #
  # If you prefer to use mocha, flexmock or RR, uncomment the appropriate line:
  #
  # config.mock_with :mocha
  # config.mock_with :flexmock
  # config.mock_with :rr

  config.infer_spec_type_from_file_location!

  config.include ActiveSupport::Testing::TimeHelpers
  config.include Capybara::DSL, :type => :request
  config.include ConfigHelper
  config.include LinkToHelper
  config.include StripAttributes::Matchers

  # Remove this line if you're not using ActiveRecord or ActiveRecord fixtures
  config.fixture_path = "#{::Rails.root}/spec/fixtures"

  # The order (!) of this is important thanks to foreign keys
  config.global_fixtures = :users,
                           :roles,
                           :users_roles,
                           :public_bodies,
                           :public_body_translations,
                           :public_body_versions,
                           :info_requests,
                           :raw_emails,
                           :incoming_messages,
                           :outgoing_messages,
                           :comments,
                           :info_request_events,
                           :track_things,
                           :has_tag_string_tags,
                           :holidays,
                           :public_body_categories,
                           :public_body_category_translations,
                           :public_body_headings,
                           :public_body_heading_translations,
                           :public_body_category_links

  # If you're not using ActiveRecord, or you'd prefer not to run each of your
  # examples within a transaction, remove the following line or assign false
  # instead of true.
  config.use_transactional_fixtures = true

  # If true, the base class of anonymous controllers will be inferred
  # automatically. This will be the default behavior in future versions of
  # rspec-rails.
  config.infer_base_class_for_anonymous_controllers = false

  # Run specs in random order to surface order dependencies. If you find an
  # order dependency and want to debug it, you can fix the order by providing
  # the seed, which is printed after each run.
  #     --seed 1234
  config.order = "random"

  # Clean up raw emails directory
  config.after(:suite) do
    raw_email_dir = File.join(Rails.root, 'files/raw_email_test')
    if File.directory?(raw_email_dir)
      FileUtils.rm_rf(raw_email_dir)
    end
    FileUtils.rm_rf(Rails.root.join('tmp', 'storage'))
  end

  # This is a workaround for a strange thing where ActionMailer::Base.deliveries isn't being
  # cleared out correctly in controller specs. So, do it here for everything.
  config.before(:each) do
    ActionMailer::Base.deliveries = []
  end

  config.before(:suite) do
    if ENV['ALAVETELI_USE_OINK']
      oink_log = Rails.root + 'log/oink.log'
      if File.exist?(oink_log)
        File.write(oink_log, '')
      end
    end

    BCrypt::Engine.cost = 1
  end

  config.after(:suite) do
    if ENV['ALAVETELI_USE_OINK']
      puts ""
      puts `oink --threshold=0 --format verbose log/oink.log`
    end
  end

  # Any test that messes with the locale needs to restore the state afterwards so that it
  # doesn't interfere with any subsequent tests. This is made more complicated by the
  # ApplicationController#set_gettext_locale which sets the locale and so you may be setting
  # the locale in your tests and not even realising it. So, let's make things easier for
  # ourselves and just always restore the locale for all tests.
  config.after(:each) do
    AlaveteliLocalization.set_locales(AlaveteliConfiguration::available_locales,
                                      AlaveteliConfiguration::default_locale)
  end

  # Turn routing-filter off in functional and unit tests as per
  # https://github.com/svenfuchs/routing-filter/blob/master/README.markdown#testing
  config.before(:each) do |example|
    RoutingFilter.active = false if [:controller, :helper, :model].include? example.metadata[:type]
  end

  config.after(:each) do |example|
    RoutingFilter.active = true if [:controller, :helper, :model].include? example.metadata[:type]
  end

  # This section makes the garbage collector run less often to speed up tests
  last_gc_run = Time.now

  config.before(:each) do
    GC.disable
  end

  config.after(:each) do
    if Time.now - last_gc_run > 4
      GC.enable
      GC.start
      last_gc_run = Time.now
    end
  end

  config.after(:each) do
    AlaveteliRateLimiter::IPRateLimiter.new(:signup).backend.destroy
  end
end

include Mail::Matchers

# Helper with_xxx methods for working with feature flags
include AlaveteliFeatures::SpecHelpers

# Use the before create job hook to simulate a race condition with
# another process by creating an acts_as_xapian_job record for the
# same model:
def with_duplicate_xapian_job_creation
  InfoRequestEvent.module_eval do
    def xapian_before_create_job_hook(action, model, model_id)
      ActsAsXapian::ActsAsXapianJob.create!(:model => model,
                                            :model_id => model_id,
                                            :action => action)
    end
  end
  yield
ensure
  InfoRequestEvent.module_eval do
    def xapian_before_create_job_hook(action, model, model_id)
    end
  end
end

def with_env_tz(new_tz = 'US/Eastern')
  old_tz, ENV['TZ'] = ENV['TZ'], new_tz
  yield
ensure
  old_tz ? ENV['TZ'] = old_tz : ENV.delete('TZ')
end

def with_active_record_default_timezone(zone)
  old_zone, ActiveRecord::Base.default_timezone = ActiveRecord::Base.default_timezone, zone
  yield
ensure
  ActiveRecord::Base.default_timezone = old_zone
end

# To test the statistics calculations, it's helpful to have the
# request fixtures in different states, but changing the fixtures
# themselves disrupts many other tests.  This function takes a
# block, and runs that block with the info requests for the
# Geraldine Quango altered so that one is hidden and there's a
# successful one.
def with_hidden_and_successful_requests
  external = info_requests(:external_request)
  chicken = info_requests(:naughty_chicken_request)
  old_external_prominence = external.prominence
  old_chicken_described_state = chicken.described_state
  begin
    external.prominence = 'hidden'
    external.save!
    chicken.described_state = 'successful'
    chicken.save!
    yield
  ensure
    external.prominence = old_external_prominence
    external.save!
    chicken.described_state = old_chicken_described_state
    chicken.save!
  end
end

# Reset the default locale, making sure that the previous default locale
# is also cleared from the fallbacks
def with_default_locale(locale)
  original_default_locale = AlaveteliLocalization.default_locale
  original_fallbacks = I18n.fallbacks
  I18n.fallbacks = nil
  AlaveteliLocalization.set_default_locale(locale)
  yield
ensure
  I18n.fallbacks = original_fallbacks
  AlaveteliLocalization.set_default_locale(original_default_locale)
end

def basic_auth_login(request, username = nil, password = nil)
  username = AlaveteliConfiguration::admin_username if username.nil?
  password = AlaveteliConfiguration::admin_password if password.nil?
  request.env["HTTP_AUTHORIZATION"] = "Basic " + Base64::encode64("#{username}:#{password}")
end

FactoryBot.definition_file_paths = [ Rails.root.join('spec', 'factories') ]
FactoryBot.reload

def normalise_whitespace(s)
  s = s.gsub(/\A\s+|\s+\Z/, "")
  s = s.gsub(/\s+/, " ")
  return s
end

def get_last_post_redirect
  # TODO: yeuch - no other easy way of getting the token so we can check
  # the redirect URL, as it is by definition opaque to the controller
  # apart from in the place that it redirects to.
  post_redirects = PostRedirect.order(id: :desc).first
end

RSpec::Matchers.define :be_equal_modulo_whitespace_to do |expected|
  match do |actual|
    normalise_whitespace(actual) == normalise_whitespace(expected)
  end
end
