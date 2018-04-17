require "base64"
require 'graphviz'
require 'json'
require 'net/http/persistent'
require "open-uri"
require 'pp'
require 'pry'
require 'repo_dependency_graph'
require 'rubygems'
require 'rubygems/dependency_installer'
require 'rubygems/package'
require 'rubygems/remote_fetcher'
require 'rubygems/request'
require 'set'
require 'zlib'

GITHUB_TOKEN = ENV['GITHUB_TOKEN']
ZENDESK_ORG = "zendesk"
ZENDESK_ORG_GITHUB = "http://www.github.com/zendesk/"
GEM_MIGRATION_BRANCH = "dtran/gem_artifactory"
GEMFILE_MIGRATION_BRANCH = "dtran/gemfile_artifactory"
PR_TITLE = "Artifactory migration"
PR_TITLE_GEMFILE = "Artifactory gemfile migration"
-PR_BODY = "[Scripted!] Update the gem server URL\n/cc @zendesk/devex @grosser\n"

GEM_DIR = "/tmp/gem_zdsys/gems"
PRIVATE_GEM_REPO = "https://gem.zdsys.com/gems/"
ARTIFACTORY_GEM_REPO = "https://zdrepo.jfrog.io/zdrepo/api/gems/gems-local/"
API_KEY = ENV['ARTIFACTORY_API_KEY']

PRIVATE_GEM_HOST = "gem.zdsys.com"
PRIVATE_GEM_USER = ENV['GEM_ZDYS_USER']
PRIVATE_GEM_PASS = ENV['GEM_ZDYS_PASS']

# monkey patch a bunch of classes/variables to to peak into the installation graph
Gem.sources = %w[https://rubygems.org https://gem.zdsys.com/gems/]

class Gem::RemoteFetcher
  def request(uri, request_class, last_modified = nil)
    proxy = proxy_for @proxy, uri
    pool  = pools_for(proxy).pool_for uri

    if uri.host == PRIVATE_GEM_HOST
      uri.user = PRIVATE_GEM_USER
      uri.password = PRIVATE_GEM_PASS
    end
    request = Gem::Request.new uri, request_class, last_modified, pool

    request.fetch do |req|
      yield req if block_given?
    end
  end
end

module OrganizationAudit
  class Repo
    attr_accessor :http_client

    def gemfile?
      !!gemfile
    end

    def gemfile
      file_list.grep(/^Gemfile$/).first
    end

    def gemfile_content
      info = call_api("contents/#{gemfile}")
      Base64.decode64(info["content"])
    end

    def gemspec_content_of_gem
      content(gemspec_file)
    end

    def get_gem_name
      c = content(gemspec_file)
      spec_name = c.split("\n").grep(/\.name\s+=/)
      if spec_name.empty?
        File.basename gemspec_file, ".gemspec"
      else
        spec_name.first.scan(/=.*/).first.gsub(/=\s+/, '').tr("'", "").tr('"', '')
      end
    end

    def create_a_branch(branch, base = "master")
      # TODO parse this
      base = call_api("git/refs/heads/#{base}")
      created = true
      begin
        existed = call_api("git/refs/heads/#{branch}")
      rescue OpenURI::HTTPError => e
        puts "Error #{e}"
        if e.message =~ /404 Not Found/
          puts "Seems that branch is not there... Try creating one #{branch}"
          created = false
        else
          return false
        end
      end

      unless created
        uri = URI.parse File.join(api_url, "git/refs")
        request = Net::HTTP::Post.new uri.path
        request.body = { :ref => "refs/heads/#{branch}", :sha => base['object']['sha'] }.to_json
        request.add_field "Content-Type", "application/json"
        request.add_field "Authorization", "token #{GITHUB_TOKEN}"
        # binding.pry
        begin
          http_client.request URI(uri), request do |response|
            puts "Status code for creating #{branch} from #{base}"
            puts response
            case response
            when Net::HTTPSuccess then
            else
              puts "Failed to create #{branch}"
              return false
            end
          end
        rescue Exception => e
          puts "Error connecting to #{uri.to_s}: #{e.message}"
          return false
        end
      end

      return true
    end

    def gem_server_type
      info = call_api("contents/#{gemfile}")
      c = Base64.decode64(info["content"])
      if c.include? ARTIFACTORY_GEM_REPO and !c.include? PRIVATE_GEM_REPO
        "artifactory"
      elsif !c.include? ARTIFACTORY_GEM_REPO and c.include? PRIVATE_GEM_REPO
        "private"
      elsif c.include? ARTIFACTORY_GEM_REPO and c.include? PRIVATE_GEM_REPO
        "mix"
      else
        "normal"
      end
    end

    def gemspec_server_type
      c = gemspec_content_of_gem
      if c.include? ARTIFACTORY_GEM_REPO and !c.include? PRIVATE_GEM_REPO
        "artifactory"
      elsif !c.include? ARTIFACTORY_GEM_REPO and c.include? PRIVATE_GEM_REPO
        "private"
      elsif c.include? ARTIFACTORY_GEM_REPO and c.include? PRIVATE_GEM_REPO
        "mix"
      else
        "normal"
      end
    end

    def update_gemspec
        info = call_api("contents/#{gemspec_file}?ref=#{GEM_MIGRATION_BRANCH}")
        c = Base64.decode64(info["content"])
        if c.include? ARTIFACTORY_GEM_REPO and !c.include? PRIVATE_GEM_REPO
          puts "Already updated #{gemspec_file}. Skipping...."
          return
        end

        c.gsub!(PRIVATE_GEM_REPO, ARTIFACTORY_GEM_REPO)
        uri = URI.parse File.join(api_url, "contents/#{gemspec_file}")
        request = Net::HTTP::Put.new uri.path
        request.body = {
          message: "Update gemspec to use artifactory",
          content: Base64.encode64(c),
          sha: info["sha"],
          branch: GEM_MIGRATION_BRANCH,
        }.to_json
        request.add_field "Content-Type", "application/json"
        request.add_field "Authorization", "token #{GITHUB_TOKEN}"

        begin
          http_client.request URI(uri), request do |response|
            case response
            when Net::HTTPSuccess then
              puts "Seems to be ok..."
              return response
            else
              puts "Failed to update #{gemspec_file}"
              puts response
            end
          end
        rescue Exception => e
          puts "Error connecting to #{uri.to_s}: #{e.message}"
        end

        return nil
    end

    def update_gemfile
        puts "Updating gemfile of #{name}"
        info = call_api("contents/#{gemfile}?ref=#{GEMFILE_MIGRATION_BRANCH}")
        c = Base64.decode64(info["content"])
        if c.include? ARTIFACTORY_GEM_REPO and !c.include? PRIVATE_GEM_REPO
          puts "Already updated #{gemspec_file}. Skipping...."
          return
        end

        c.gsub!(PRIVATE_GEM_REPO, ARTIFACTORY_GEM_REPO)
        uri = URI.parse File.join(api_url, "contents/#{gemfile}")
        request = Net::HTTP::Put.new uri.path
        request.body = {
          message: "Update gemfile to use artifactory",
          content: Base64.encode64(c),
          sha: info["sha"],
          branch: GEMFILE_MIGRATION_BRANCH,
        }.to_json
        request.add_field "Content-Type", "application/json"
        request.add_field "Authorization", "token #{GITHUB_TOKEN}"

        begin
          http_client.request URI(uri), request do |response|
            case response
            when Net::HTTPSuccess then
              puts "Seems to be ok..."
              return response
            else
              puts "Failed to update #{gemfile}"
              puts response
            end
          end
        rescue Exception => e
          puts "Error connecting to #{uri.to_s}: #{e.message}"
        end

        return nil
    end

    def submit_pr
      pulls = call_api("/pulls")
      pending = pulls.select { |p| p["title"].include? PR_TITLE }
      if pending.any? or (gemspec_content.include? ARTIFACTORY_GEM_REPO and !gemspec_content.include? PRIVATE_GEM_REPO)
        puts "#{name} seems to be migrated. Skipping..."
        return
      end

      uri = URI.parse File.join(api_url, "pulls")
      request = Net::HTTP::Post.new uri.path
      request.body = {
        title: PR_TITLE,
        head: GEM_MIGRATION_BRANCH,
        base: "master",
        body: PR_BODY,
      }.to_json
      request.add_field "Content-Type", "application/json"
      request.add_field "Authorization", "token #{GITHUB_TOKEN}"

      begin
        http_client.request URI(uri), request do |response|
          case response
          when Net::HTTPSuccess then
            puts "PR seems to be ok..."
            return response
          else
            puts "Failed to create PR #{gemspec_file}"
            puts response
          end
        end
      rescue Exception => e
        puts "Error connecting to #{uri.to_s}: #{e.message}"
      end
    end

    def submit_pr_gemfile
      puts "Submitting PR to update gemfile of #{name}"
      pulls = call_api("/pulls")
      pending = pulls.select { |p| p["title"].include? PR_TITLE_GEMFILE }
      if pending.any? or (gemfile_content.include? ARTIFACTORY_GEM_REPO and !gemfile_content.include? PRIVATE_GEM_REPO)
        puts "#{name} seems to be migrated. Skipping..."
        return
      end
      puts "????"
      puts pulls

      uri = URI.parse File.join(api_url, "pulls")
      request = Net::HTTP::Post.new uri.path
      request.body = {
        title: PR_TITLE_GEMFILE,
        head: GEMFILE_MIGRATION_BRANCH,
        base: "master",
        body: PR_BODY,
      }.to_json
      request.add_field "Content-Type", "application/json"
      request.add_field "Authorization", "token #{GITHUB_TOKEN}"

      begin
        http_client.request URI(uri), request do |response|
          case response
          when Net::HTTPSuccess then
            puts "PR seems to be ok..."
            return response
          else
            puts "Failed to create PR #{gemfile}"
            puts response
          end
        end
      rescue Exception => e
        puts "Error connecting to #{uri.to_s}: #{e.message}"
      end
    end
  end
end

# End of monkey patch stuffs

# https://github.com/rubygems/rubygems/blob/master/lib/rubygems/commands/push_command.rb#L93
def upload_gem(http_client, gem_path)
  uri = URI.parse "#{ARTIFACTORY_GEM_REPO}/api/v1/gems"
  request = Net::HTTP::Post.new uri.path
  request.body = Gem.read_binary gem_path
  request.add_field "Content-Length", request.body.size
  request.add_field "Content-Type",   "application/octet-stream"
  request.add_field "Authorization", API_KEY

  begin
    http_client.request URI(uri), request do |response|
      puts "Status code for uploading #{gem_path}: #{response.code}"
      case response
      when Net::HTTPSuccess then
      else
        puts "Failed to upload #{gem_path}"
      end
    end
  rescue Exception => e
    puts "Error connecting to #{uri.to_s}: #{e.message}"
  end
end

def extract_names_and_versions(list, pattern)
  list.map do |name|
    if pattern =~ name
      [$1, $2]
    else
      [name]
    end
  end
end

# https://github.com/rubygems/rubygems/blob/master/lib/rubygems/command.rb#L200
def get_all_gem_names_and_versions(gem_names)
  extract_names_and_versions gem_names, /\A(.*):(#{Gem::Requirement::PATTERN_RAW})\z/
end

def parse_all_gem_files_names_and_versions(gem_file_names)
  extract_names_and_versions gem_file_names, /\A(.*)-(#{Gem::Version::VERSION_PATTERN})\z/
end

# https://github.com/rubygems/rubygems/blob/master/lib/rubygems/commands/install_command.rb#L185
def gem_dependency name, version
  req = Gem::Requirement.create(version)
  inst = Gem::DependencyInstaller.new(:domain => :remote)
  request_set = inst.resolve_dependencies name, req
  a = request_set.sorted_request
end

def gem_spec name, version
  req = Gem::Requirement.create(version)
  dep = Gem::Dependency.new name, req

  found, _ = Gem::SpecFetcher.fetcher.spec_for_dependency dep
  return found
end

def mirror_gems_to_artifactory()
  http_client = Net::HTTP::Persistent.new("uploader", :ENV)

  Dir["#{GEM_DIR}/*.gem"].each do |gem_path|
    puts "Uploading #{gem_path}"
    upload_gem(http_client, gem_path)
  end
end

class Graph
  class Node
    attr_accessor :name, :level

    def initialize(name, level)
      @name = name
      @level = level
    end

    def to_s
      "#{@name}"
    end
  end

  attr_accessor :dep_list, :preq_list, :in_degree, :info

  def initialize
    @dep_list = {}
    @preq_list = {}
    @in_degree = {}
    @info = {}
    @graph_viz = GraphViz.new(:G)
  end

  def add(name)
    @dep_list[name] = Set.new
    @preq_list[name] = Set.new
    @in_degree[name] = 0
    @graph_viz.add_nodes(name)
  end

  def add_preq(preq, name)
    @preq_list[preq].add(name)
    @in_degree[preq] = @preq_list.length
    @graph_viz.add_edges(@graph_viz.get_node(preq), @graph_viz.get_node(name))
  end

  def add_dep(name, dep)
    @dep_list[name].add(dep)
  end

  def topo_dep_sort
    queue = []
    dep_groups = []
    visited = {} # for cyclic detection if needed

    dep_list.each_pair { |name, deps| queue << Node.new(name, 0) unless deps.length > 0 }

    while queue.length > 0 do
      node = queue.shift
      visited[node.name] = true

      if node.level == dep_groups.length
        dep_groups << [node.name]
      else
        dep_groups[node.level] << node.name
      end

      if preq_list.key?(node.name)
        preq_list[node.name].each do |name|
          dep_list[name].delete(node.name)
          if dep_list[name].empty?
            queue << Node.new(name, node.level + 1)
          end
        end
      end

      preq_list.delete(node.name)
    end

    dep_groups
  end

  def to_image(filename)
    @graph_viz.output( :png => "#{filename}.png" )
  end
end

def newer_gem_version a, b
  return Gem::Version.new(a) > Gem::Version.new(b)
end

# Only generate the gem dependency graph assuming
# the latest versions of everything
def gem_dependencies
  gem_names = []
  Dir["#{GEM_DIR}/*.gem"].each do |gem_path|
    gem_names << (File.basename gem_path, ".gem")
  end

  gem_set  = {}
  gem_graph = Graph.new
  parse_all_gem_files_names_and_versions(gem_names).each do |name, version|
    if !gem_set.key?(name) or newer_gem_version(version, gem_set[name])
      gem_graph.add(name) unless gem_set.key?(name)
      gem_set[name] = version
    end
    # puts gem_dependency(name, version).length
  end


  idx = 0
  gem_set.each do |name, version|
    # puts "#{name} ---> #{version}"
    spec = gem_spec(name, version)
    idx += 1
    if spec
      gem_graph.info[name] = spec
      spec[0][0].dependencies.each do |dep|
        # Only store private gem dependencies
        if gem_set.key?(dep.name)
          # name --(depends on)--> dep
          gem_graph.add_dep name, dep.name
          # dep --(is required for)--> name
          gem_graph.add_preq dep.name, name
        end
      end
    else
      puts "Failed to fetch spec for #{name}-#{version}"
    end
    # if idx > 5
    #   break
    # end
  end

  gem_graph
end

def output_gem_deps
  gem_graph = gem_dependencies
  groups = gem_graph.topo_dep_sort

  if groups.any?
    independent_gems = groups[0].select { |name| gem_graph.in_degree[name] == 0 }
  else
    independent_gems = []
  end

  def print_col(arr)
    arr.each do |item|
      puts item
    end
  end

  puts "Independent group"
  print_col independent_gems
  puts

  groups.each_with_index do |g, i|
    puts "Group #{i+1}"
    if i == 0
      print_col g.select{ |name| gem_graph.in_degree[name] > 0}
    else
      print_col g
    end
    puts
  end
end

def project_dependencies(org)
  dump_path = "/tmp/#{org}_repo_deps.dump"

  ## Slow so don't do it often
  # repo_deps = RepoDependencyGraph.dependencies(
  #   token: GITHUB_TOKEN,
  #   organization: org,
  #   private: true,
  # )
  # File.open(dump_path, 'wb') { |f| f.write(Marshal.dump(repo_deps)) }

  repo_deps = Marshal.load(File.read(dump_path))

  repo_deps
end

def project_gem_dependencies
  repo_deps = project_dependencies(ZENDESK_ORG)
  gem_graph = gem_dependencies

  repo_graph = Graph.new
  # Incrementally bulid the dependency starting
  # from the set of gem
  visited = Set.new(gem_graph.info.keys)
  while true
    to_be_added = {}
    repo_deps.each_pair { |name, deps|
      if visited.include? name
        next
      end
      uses = Set.new(deps.map { |d| d[0] }) & visited
      # puts "#{name} uses #{uses.to_a}"
      if uses.any?
        to_be_added[name] = uses
      end
    }

    to_be_added.each_pair do |name, deps|
      repo_graph.add(name) unless visited.include? name
      deps.each do |dep|
        repo_graph.add(dep) unless visited.include? dep
        unless gem_graph.info.key? name or gem_graph.info.key? dep
          repo_graph.add_dep(name, dep)
          repo_graph.add_preq(dep, name)
        end
      end
    end

    if to_be_added.empty?
      break
    else
      visited += Set.new(to_be_added.keys)
    end
  end

  groups = repo_graph.topo_dep_sort

  groups.each_with_index do |g, i|
    puts "Group #{i}: #{g.length} repos"
    pp g
  end

  repo_graph
end

def fetch_gem_projects
  org = ZENDESK_ORG
  dump_path = "/tmp/#{org}_gem_repo_deps.dump"

  # opts = {
  #   token: GITHUB_TOKEN,
  #   organization: org,
  # }
  # private_repos = OrganizationAudit::Repo.all(opts).sort_by(&:name).select(&:private?)
  # gem_projects = []
  # while private_repos.any?
  #   puts "Remaining: #{private_repos.size}"
  #   repo = private_repos.shift
  #   begin
  #     puts "Checking #{repo.name}"
  #   rescue Exception => e
  #     puts "Got exceptin #{e}"
  #     puts "Skipping"
  #     next
  #   end
  #   begin
  #     if repo.gem?
  #       gem_projects << repo
  #       puts "Adding repo #{repo.name}"
  #       File.open(dump_path, 'wb') { |f| f.write(Marshal.dump(gem_projects)) }
  #     end
  #   rescue
  #     puts "Retrying #{repo.name}" unless repo.nil?
  #     private_repos << repo unless repo.nil?
  #   end
  # end
  # File.open(dump_path, 'wb') { |f| f.write(Marshal.dump(gem_projects)) }

  gem_projects = Marshal.load(File.read(dump_path))

  gem_projects
end

def fetch_gemfile_projects
  org = ZENDESK_ORG
  dump_path = "/tmp/#{org}_gemfile_repo_deps.dump"

  # opts = {
  #   token: GITHUB_TOKEN,
  #   organization: org,
  # }
  # private_repos = OrganizationAudit::Repo.all(opts).sort_by(&:name).select(&:private?)
  # projects = []
  # while private_repos.any?
  #   puts "Remaining: #{private_repos.size}"
  #   repo = private_repos.shift
  #   begin
  #     puts "Checking #{repo.name}"
  #   rescue Exception => e
  #     puts "Got exceptin #{e}"
  #     puts "Skipping"
  #     next
  #   end
  #   begin
  #     if repo.gemfile?
  #       projects << repo
  #       puts "Adding repo #{repo.name}"
  #       File.open(dump_path, 'wb') { |f| f.write(Marshal.dump(projects)) }
  #     end
  #   rescue Exception => e
  #     puts "Exception #{e}"
  #     puts "Retrying #{repo.name}" unless repo.nil?
  #     private_repos << repo unless repo.nil?
  #     break
  #   end
  # end
  # File.open(dump_path, 'wb') { |f| f.write(Marshal.dump(projects)) }

  projects = Marshal.load(File.read(dump_path))

  projects
end

def save_local(path, obj)
  File.open(path, 'wb') { |f| f.write(Marshal.dump(obj)) }
end

def load_local(path)
  Marshal.load(File.read(path))
end

def count_migration_gemfile_projects
  counter_cache_path = '/tmp/zendesk_server_type_counter.dump'

  projects = fetch_gemfile_projects

  # counter = {}
  # projects.each do |project|
  #   puts "Tracking #{project.name}"
  #   type = project.gem_server_type
  #   puts "gem server type: #{type}"
  #   if counter.key? type
  #     counter[type] << project
  #   else
  #     counter[type] = [project]
  #   end
  # end
  # save_local(counter_cache_path, counter)

  counter = load_local(counter_cache_path)

  counter
end

def track_migrations_gemfile_projects
  puts "MIGRATION TRACKING FOR RUBY PROJECTS (GEMFILES)"
  puts

  counter = count_migration_gemfile_projects

  counter.each_pair do |k,v|
    next unless k != "normal"
    # puts "#{k} - #{v.size} repos"
    puts "#{k}"
    x = v.map do |item| item.url end
    puts x
    puts
    puts
  end
  puts
  puts
end

def track_migrations_gem_projects
  puts "MIGRATION TRACKING FOR GEM PROJECTS (GEMSPECS)"
  puts
  counter_cache_path = '/tmp/zendesk_server_type_counter_gem_projects.dump'

  projects = fetch_gem_projects

  # counter = {}
  # projects.each do |project|
  #   puts "Tracking #{project.name}"
  #   type = project.gemspec_server_type
  #   puts "gem server type: #{type}"
  #   if counter.key? type
  #     counter[type] << project
  #   else
  #     counter[type] = [project]
  #   end
  # end
  # save_local(counter_cache_path, counter)

  counter = load_local(counter_cache_path)

  counter.each_pair do |k,v|
    next unless k != "normal"
    # puts "#{k} - #{v.size} repos"
    puts "Status: #{k}"
    x = v.map do |item| item.url end
    puts x
    puts
    puts
  end
  puts
  puts
end

def auto_pr_gem_project(repo, http_client)
  repo.http_client = http_client

  gemspec = repo.gemspec_content_of_gem
  if gemspec.include? PRIVATE_GEM_REPO
    ok = repo.create_a_branch(GEM_MIGRATION_BRANCH)
    if ok
      repo.update_gemspec
      repo.submit_pr
    else
      puts "Failed to check/add pr for this #{repo.name}"
    end
  end

end

def migrate_gem_projects
  org = ZENDESK_ORG
  dump_path = "/tmp/#{org}_gem_specs.dump"
  http_client = Net::HTTP::Persistent.new("repo_bot", :ENV)

  gem_projects = fetch_gem_projects
  gem_graph = gem_dependencies
  groups = gem_graph.topo_dep_sort

  # gem_specs = gem_projects.map {|repo| repo.get_gem_name }
  # File.open(dump_path, 'wb') { |f| f.write(Marshal.dump(gem_specs)) }
  # gem_specs = Marshal.load(File.read(dump_path))

  # Migrate indepdent gems
  batch = 0
  gems = groups[0].select { |name| gem_graph.in_degree[name] == 0 }

  unknown_gems = []
  gems.each { |gem_name|
    puts "Checking #{gem_name}"
    match = gem_projects.select { |repo|
      repo.get_gem_name == gem_name
    }
    if match.empty?
      unknown_gems << gem_name
    else
      puts "Creating a PR for #{gem_name}"
      auto_pr_gem_project(match[0], http_client)
      break
    end
  }

  File.open("/tmp/gem_batch_#{batch}_unknown", 'w') { |f| f.write({unknown: unknown_gems}.to_json) }
end

def auto_pr_gemfile_project(repo, http_client)
  repo.http_client = http_client

  gemfile = repo.gemfile_content
  if gemfile.include? PRIVATE_GEM_REPO
    ok = repo.create_a_branch(GEMFILE_MIGRATION_BRANCH)
    puts "OK #{ok}"
    if ok
      repo.update_gemfile
      repo.submit_pr_gemfile
    else
      puts "Failed to check/add pr for this #{repo.name}"
    end
  end
end

def migrate_ruby_projects
  http_client = Net::HTTP::Persistent.new("repo_bot", :ENV)

  counter = count_migration_gemfile_projects

  repos = counter.inject([]) do |acc, (k ,v)|
    acc.concat v unless k != "private" && k != "mix"
    acc
  end
  puts repos.length

  repos.each do |repo|
    auto_pr_gemfile_project(repo, http_client)
    break
  end
end

def cross_check
  from_specs = Set.new
  local = Set.new
  ver = 4.8
  files = [ "specs.#{ver}", "prerelease_specs.#{ver}", "latest_specs.#{ver}" ]
  files.each do |file|
    path = "/tmp/gem_zdsys/#{file}"
    gems = Marshal.load(File.read(path))
    gems.each do |gem|
      from_specs.add "#{gem[0]}-#{gem[1].version}"
    end
  end
  Dir["#{GEM_DIR}/*.gem"].each do |gem_path|
    gem_name = File.basename gem_path, '.gem'
    local.add gem_name
  end

  diff = from_specs - local
  puts diff.to_a
end

# Main here

# mirror all gems to artifactory
# mirror_gems_to_artifactory

###########################################
# Update projects to use artifactory
# project_gem_dependencies

# migrate gems projects to artifactory
# output_gem_deps
# migrate_gem_projects
migrate_ruby_projects

# cross_check

# track_migrations_gemfile_projects
# track_migrations_gem_projects
