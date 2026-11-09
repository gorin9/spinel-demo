require 'fileutils'
require ENV.fetch('SPNL_ERB_LIB', (File.file?(File.expand_path('../vendor/tools/spnl-erb/lib/spnl_erb.rb', __dir__)) ? File.expand_path('../vendor/tools/spnl-erb/lib/spnl_erb', __dir__) : File.expand_path('../../spnl-erb/lib/spnl_erb', __dir__)))
require ENV.fetch('SPNL_ROUTER_LIB', (File.file?(File.expand_path('../vendor/tools/spnl-router/lib/spnl_router.rb', __dir__)) ? File.expand_path('../vendor/tools/spnl-router/lib/spnl_router', __dir__) : File.expand_path('../../spnl-router/lib/spnl_router', __dir__)))
require ENV.fetch('SPNL_SCHEMA_LIB', (File.file?(File.expand_path('../vendor/tools/spnl-schema/lib/spnl_schema.rb', __dir__)) ? File.expand_path('../vendor/tools/spnl-schema/lib/spnl_schema', __dir__) : File.expand_path('../../spnl-schema/lib/spnl_schema', __dir__)))
root=File.expand_path('..',__dir__)
Dir.chdir(root) do
  %w[layout home users].each do |name|
    path="views/site/#{name}.html.erb"
    File.write(path.sub(/\.erb$/,'.generated.rb'),SpnlErb.compile_class(File.read(path),class_name:'Unused',target_class:'SiteController',mode: :controller,method_name:'render_'+name,source_path:path))
  end
  File.write('app/site_router.generated.rb',SpnlRouter.generate(File.read('app/site_controller.rb'),target_module:'SiteRouter'))
  table=SpnlSchema.parse(File.read('db/schema.sql')).first
  File.write('app/models/user.generated.rb',SpnlSchema.emit_class(table))
  FileUtils.mkdir_p('sig')
  File.write('sig/user.rbs',SpnlSchema.emit_rbs(table))
end
puts 'Generated views, routes, model and RBS'
