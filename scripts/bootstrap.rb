require 'json'
require 'fileutils'
require 'open3'
root=File.expand_path('..',__dir__)
lock=JSON.parse(File.read(File.join(root,'tools.lock.json')))
lock.each do |name,sha|
  raise 'invalid tool name/ref' unless name.match?(/\Aspnl-(erb|router|schema)\z/) && sha.match?(/\A[0-9a-f]{40}\z/)
  dest=File.join(root,'vendor','tools',name)
  if File.directory?(dest)
    actual,status=Open3.capture2('git','-C',dest,'rev-parse','HEAD')
    dirty,_=Open3.capture2('git','-C',dest,'status','--porcelain')
    raise "#{dest} differs from tools.lock.json; inspect it before replacing" unless status.success? && actual.strip==sha && dirty.empty?
    next
  end
  FileUtils.mkdir_p(File.dirname(dest))
  raise 'clone failed' unless system('git','clone','--quiet','https://github.com/gorin9/'+name+'.git',dest)
  raise 'checkout failed' unless system('git','-C',dest,'checkout','--quiet',sha)
end
puts 'Pinned CRuby build tools ready under vendor/tools'
