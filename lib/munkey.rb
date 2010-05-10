require 'uri'
require 'ftp_sync'
require 'yaml'
require 'gitignore_parser'

class Munkey
  DEFAULT_BRANCH = 'munkey'
  
  class << self
    def clone(ftpsrc, repo_path, options = {})
      src = URI::parse(ftpsrc)
      raise InvalidSource unless src.is_a?(URI::FTP)
      
      repo = create_repo(repo_path, options)
      repo.save_ftp_details(src)
      repo.pull_ftp_files
      repo.commit_changes
      repo.create_branch
      repo
    end
    
    private
      def create_repo(repo_path, options = {})
        return false unless system("git init #{repo_path}")
        if options[:ignores]
          File.open(File.join(repo_path, '.gitignore'), 'w') do |f|
            f.write options[:ignores]
          end
          system("cd #{repo_path} && git add .gitignore")
        end
        new(repo_path)
      end
  end
  
  def initialize(gitpath)
    @gitpath = gitpath
    munkey_file = File.join(gitpath, '.git', 'munkey.yml')
    @ftpdetails = YAML.load_file(munkey_file) if File.exist?(munkey_file)
  end
  
  def pull
    tmp_repo = clone_to_tmp
    pull_ftp_files(tmp_repo)
    commit_changes(tmp_repo)
    push_into_base_repo(tmp_repo)
    FileUtils.rm_rf(tmp_repo)
    merge_foreign_changes
  end
  
  def push
    changes = files_changed_between_branches
    update_ftp_server(changes)
    tmp_repo = clone_to_tmp
    merge_pushed_changes(tmp_repo)
    push_into_base_repo(tmp_repo)
    FileUtils.rm_rf(tmp_repo)
  end
  
  def save_ftp_details(ftp_uri)
    @ftpdetails = { :host => ftp_uri.host, :path => "/#{ftp_uri.path}", :user => ftp_uri.user, :password => ftp_uri.password }
    File.open File.join(@gitpath, '.git', 'munkey.yml'), 'w' do |f|
      f.write @ftpdetails.to_yaml
    end
  end
  
  def pull_ftp_files(dst = nil)
    dst ||= @gitpath
    gitignore = GitignoreParser.parse(dst)
    ftp = FtpSync.new(@ftpdetails[:host], @ftpdetails[:user], @ftpdetails[:password], :ignore => gitignore)
    ftp.pull_dir(dst, @ftpdetails[:path], { :delete => true }) do |p|
      Dir.chdir(dst) do
        relpath = p.gsub %r{^#{Regexp.escape(dst)}\/}, ''
        system("git rm -r '#{relpath}'")
      end
    end  
  end
  
  def commit_changes(dst = nil)
    Dir.chdir(dst || @gitpath) do
      system("git add .") && system("git commit -m 'Pull from ftp://#{@ftpdetails[:host]}#{@ftpdetails[:path]} at #{Time.now.to_s}'")
    end
  end
  
  def create_branch(branch_name = DEFAULT_BRANCH)
    Dir.chdir(@gitpath) do
      system("git branch #{branch_name}")
    end
  end
  
  def clone_to_tmp(branch = DEFAULT_BRANCH)
    tmp_repo = File.join ENV['TMPDIR'], create_tmpname
    system("git clone -b #{branch} #{@gitpath} #{tmp_repo}")
    tmp_repo
  end
  
  def push_into_base_repo(tmp_repo, branch = DEFAULT_BRANCH)
    Dir.chdir(tmp_repo) do
      system("git push origin #{branch}:#{branch}")
    end
  end
  
  def merge_foreign_changes(branch = DEFAULT_BRANCH)
    Dir.chdir(@gitpath) do
      system("git merge #{branch}")
    end
  end
  
  def merge_pushed_changes(tmp_repo)
    Dir.chdir(tmp_repo) do
      system("git pull origin master")
    end
  end
  
  def files_changed_between_branches(branch = DEFAULT_BRANCH)
    changes = { :changed => [], :removed => [] }
    Dir.chdir(@gitpath) do
      `git diff --name-status #{branch} master`.strip.split("\n").each do |f|
        status, name = f.split(/\s+/, 2)
        if status == "D"
          changes[:removed] << name
        else
          changes[:changed] << name
        end
      end
    end
    
    changes
  end
  
  def update_ftp_server(changes)
    ftp = FtpSync.new(@ftpdetails[:host], @ftpdetails[:user], @ftpdetails[:password])

    unless changes[:changed].size == 0
      ftp.push_files @gitpath, @ftpdetails[:path], changes[:changed]
    end
    
    unless changes[:removed].size == 0
      ftp.remove_files @ftpdetails[:path], changes[:removed]
    end
  end
  
  private
  
    def create_tmpname
      tmpname = ''
      char_list = ("a".."z").to_a + ("0".."9").to_a
			1.upto(20) { |i| tmpname << char_list[rand(char_list.size)] }
			return tmpname
    end
end