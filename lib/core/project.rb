require "core/rake_ext"
require "core/common"

module Buildr

  # An inherited attribute gets its value an accessor with the same name.
  # But if the value is not set, it will obtain a value from the parent,
  # so setting the value in the parent make it accessible to all the children
  # that did not override it.
  module InheritedAttributes

    class << self
    private
      def included(mod)
        mod.extend(self)
      end
    end

    # :call-seq:
    #    inherited_attr(symbol, default?)
    #    inherited_attr(symbol) { |obj| ... }
    #
    # Defines an inherited attribute. The first form can provide a default value
    # for the top-level object, used if the attribute was not set. The second form
    # provides a default value by calling the block.
    #
    # For example:
    #   inherited_attr :version
    #   inherited_attr :src_dir, "src"
    #   inherited_attr(:created_on) { Time.now }
    def inherited_attr(symbol, default = nil, &block)
      block ||= proc { default }
      attr_accessor symbol
      define_method "#{symbol}_with_inheritence" do
        value = send("#{symbol}_without_inheritence")
        if value.nil?
          value = parent ? parent.send(symbol) : self.instance_eval(&block)
          send "#{symbol}=", value
        end
        value
      end
      alias_method_chain symbol, :inheritence
    end
  end


  # A project definition is where you define all the tasks associated with
  # the project you're building.
  #
  # The project itself will define several life cycle tasks for you. For example,
  # it automatically creates a compile task that will compile all the source files
  # found in src/main/java into target/classes, a test task that will compile source
  # files from src/test/java and run all the JUnit tests found there, and a build
  # task to compile and then run the tests.
  #
  # You use the project definition to enhance these tasks, for example, telling the
  # compile task which class path dependencies to use. Or telling the project how
  # to package an artifact, e.g. creating a JAR using <tt>package :jar</tt>.
  #
  # You can also define additional tasks that are executed by project tasks,
  # or invoked from rake.
  #
  # Tasks created by the project are all prefixed with the project name, e.g.
  # the project foo creates the task foo:compile. If foo contains a sub-project bar,
  # the later will define the task foo:bar:compile. Since the compile task is
  # recursive, compiling foo will also compile foo:bar.
  #
  # If you run:
  #   buildr compile
  # from the command line, it will execute the compile task of the current project.
  #
  # Projects and sub-projects follow a directory heirarchy. The Buildfile is assumed to
  # reside in the same directory as the top-level project, and each sub-project is
  # contained in a sub-directory in the same name. For example:
  #   /home/foo
  #   |__ Buildfile
  #   |__ src/main/java
  #   |__ foo
  #       |__ src/main/java
  #
  # The default structure of each project is assumed to be:
  #   src
  #   |__main
  #   |  |__java           <-- Source files to compile
  #   |  |__resources      <-- Resources to copy
  #   |  |__webapp         <-- For WARs
  #   |__test
  #   |  |__java           <-- Source files to compile (tests)
  #   |  |__resources      <-- Resources to copy (tests)
  #   |__target            <-- Packages created here
  #   |  |__classes        <-- Generated when compiling
  #   |  |__test-classes   <-- Generated when compiling tests
  #
  # You can only define a project once using #define. Afterwards, you can obtain the project
  # definition using #project. The order in which you define projects is not important,
  # project definitions are evaluated when you ask for them. Circular dependencies will not
  # work. Rake tasks are only created after the project is evaluated, so if you need to access
  # a task (e.g. compile) use <code>project("foo").compile</code> instead of <code>task("foo:compile")</code>.
  #
  # For example:
  #   define "myapp", :version=>"1.1" do
  #
  #     define "wepapp" do
  #       compile.with project("myapp:beans")
  #       package :war
  #     end
  #
  #     define "beans" do
  #       compile.with DEPENDS
  #       package :jar
  #     end
  #   end
  #
  #   puts projects.map(&:name)
  #   => [ "myapp", "myapp:beans", "myapp:webapp" ]
  #   puts project("myapp:webapp").parent.name
  #   => "myapp"
  #   puts project("myapp:webapp").compile.classpath.map(&:to_spec)
  #   => "myapp:myapp-beans:jar:1.1"
  class Project < Rake::Task

    class << self

      # :call-seq:
      #   define(name, properties?) { |project| ... } => project
      #
      # See Buildr#define.
      def define(name, properties, &block) #:nodoc:
        # Make sure a sub-project is only defined within the parent project,
        # to prevent silly mistakes that lead to inconsistencies (e.g.
        # namespaces will be all out of whack).
        Rake.application.current_scope == name.split(":")[0...-1] or
          raise "You can only define a sub project (#{name}) within the definition of its parent project"

        @projects ||= {}
        raise "You cannot define the same project (#{name}) more than once" if @projects[name]
        Project.define_task(name).tap do |project|
          # Define the project to prevent duplicate definition.
          @projects[name] = project
          # Set the project properties first, actions may use them.
          properties.each { |name, value| project.send "#{name}=", value } if properties
          project.enhance do |project|
            @on_define.each { |callback| callback[project] }
          end if @on_define
          # Enhance the project using the definition block.
          project.enhance { project.instance_eval &block } if block

          # Top-level project? Invoke the project definition. Sub-project? We don't invoke
          # the project definiton yet (allow project() calls to establish order of evaluation),
          # but must do so before the parent project's definition is done. 
          project.parent.enhance { project.invoke } if project.parent
        end
      end

      # :call-seq:
      #   project(name) => project
      #
      # See Buildr#project.
      def project(*args) #:nodoc:
        options = args.pop if Hash === args.last
        rake_check_options options, :scope if options
        raise ArgumentError, "Only one project name at a time" unless args.size == 1
        @projects ||= {}
        name = args.first
        if options && options[:scope]
          # We assume parent project is evaluated.
          project = options[:scope].split(":").inject([[]]) { |scopes, scope| scopes << (scopes.last + [scope]) }.
            map { |scope| @projects[(scope + [name]).join(":")] }.
            select { |project| project }.last
        end
        unless project
          # Parent project not evaluated.
          name.split(":").tap { |parts| @projects[parts.first].invoke if parts.size > 1 }
          project = @projects[name]
        end
        raise "No such project #{name}" unless project
        project.invoke
        project
      end

      # :call-seq:
      #   projects(*names) => projects
      #
      # See Buildr#projects.
      def projects(*names) #:nodoc:
        options = names.pop if Hash === names.last
        rake_check_options options, :scope if options
        @projects ||= {}
        names = names.flatten
        if options && options[:scope]
          # We assume parent project is evaluated.
          if names.empty?
            parent = @projects[options[:scope].to_s] or raise "No such project #{options[:scope]}"
            @projects.values.select { |project| project.parent == parent }.each { |project| project.invoke }.
              map { |project| [project] + projects(:scope=>project) }.flatten.sort_by(&:name)
          else
            names.uniq.map { |name| project(name, :scope=>options[:scope]) }
          end
        elsif names.empty?
          # Parent project(s) not evaluated so we don't know all the projects yet.
          @projects.values.each(&:invoke)
          @projects.keys.map { |name| project(name) or raise "No such project #{name}" }.sort_by(&:name)
        else
          # Parent project(s) not evaluated, for the sub-projects we may need to find.
          names.map { |name| name.split(":") }.select { |name| name.size > 1 }.map(&:first).uniq.each { |name| project(name) }
          names.uniq.map { |name| project(name) or raise "No such project #{name}" }.sort_by(&:name)
        end
      end

      # :call-seq:
      #   clear()
      #
      # Discard all project definitions.
      def clear()
        @projects.clear if @projects
      end

      # :call-seq:
      #   local_task(name)
      #   local_task(name) { |name| ... }
      #
      # Defines a local task with an optional execution message.
      #
      # A local task is a task that executes a task with the same name, defined in the
      # current project, the project's with a base directory that is the same as the
      # current directory.
      #
      # Complicated? Try this:
      #   buildr build
      # is the same as:
      #   buildr foo:build
      # But:
      #   cd bar
      #   buildr build
      # is the same as:
      #   buildr foo:bar:build
      #
      # The optional block is called with the project name when the task executes
      # and returns a message that, for example "Building project #{name}".
      def local_task(args, &block)
        task args do |task|
          local_projects do |project|
            puts block.call(project.name) if block && verbose
            task("#{project.name}:#{task.name}").invoke
          end
        end
      end

      # :call-seq:
      #   on_define() { |project| ... }
      #
      # The Project class defines minimal behavior, only what is documented here.
      # To extend its definition, other modules use Project#on_define to incorporate
      # code called during a new project's definition.
      #
      # For example:
      #   # Set the default version of each project to "1.0".
      #   Project.on_define { |project| project.version ||= "1.0" }
      #
      # Since each project definition is essentially a task, if you need to do work
      # at the end of the project definition (after the block is executed), you can
      # enhance it from within #on_define.
      def on_define(&block)
        (@on_define ||= []) << block if block
      end

      def scope_name(scope, task_name) #:nodoc:
        task_name
      end

      def local_projects(dir = nil, &block) #:nodoc:
        dir = File.expand_path(dir || Rake.application.original_dir)
        projects = Project.projects.select { |project| project.base_dir == dir }
        if projects.empty? && dir != Dir.pwd && File.dirname(dir) != dir
          local_projects(File.dirname(dir), &block)
        elsif block
          if projects.empty?
            warn "No projects defined for directory #{Rake.application.original_dir}" if verbose
          else
            projects.each { |project| block[project] }
          end
        else
          projects
        end
      end

      # :call-seq:
      #   task_in_parent_project(task_name) => task_name or nil
      #
      # Assuming the task name is prefixed with the current project, finds and returns a task with the
      # same name in a parent project.  Call this with "foo:bar:test" will return "foo:test", but call
      # this with "foo:test" will return nil.
      def task_in_parent_project(task_name)
        namespace = task_name.split(":")
        last_name = namespace.pop
        namespace.pop
        Rake.application.lookup((namespace + [last_name]).join(":"), []) unless namespace.empty?
      end

    end

    include InheritedAttributes

    # The project name. For example, "foo" for the top-level project, and "foo:bar"
    # for its sub-project.
    attr_reader :name

    # The parent project if this is a sub-project.
    attr_reader :parent

    def initialize(*args) #:nodoc:
      super
      split = name.split(":")
      if split.size > 1
        # Get parent project, but do not invoke it's definition to prevent circular
        # dependencies (it's being invoked right now, so calling project() will fail).
        @parent = task(split[0...-1].join(":"))
        raise "No parent project #{split[0...-1].join(":")}" unless @parent && Project === parent
      end
    end

    # :call-seq:
    #   base_dir() => path
    #
    # Returns the project's base directory.
    #
    # The Buildfile defines top-level project, so it's logical that the top-level project's
    # base directory is the one in which we find the Buildfile. And each sub-project has
    # a base directory that is one level down, with the same name as the sub-project.
    #
    # For example:
    #   /home/foo/          <-- base_directory of project "foo"
    #   /home/foo/Buildfile <-- builds "foo"
    #   /home/foo/bar       <-- sub-project "foo:bar"
    def base_dir()
      if @base_dir.nil?
        if parent
          # For sub-project, a good default is a directory in the parent's base_dir,
          # using the same name as the project.
          @base_dir = File.join(parent.base_dir, name.split(":").last)
        else
          # For top-level project, a good default is the directory where we found the Buildfile.
          @base_dir = Dir.pwd
        end
      end
      @base_dir
    end

    # :call-seq:
    #   base_dir = dir
    #
    # Sets the project's base directory. Allows you to specify a base directory by calling
    # this accessor, or with the :base_dir property when calling #define.
    #
    # You can only set the base directory once for a given project, and only before accessing
    # the base directory (for example, by calling #file or #path_to).
    # Set the base directory. Note: you can only do this once for a project,
    # and only before accessing the base directory. If you try reading the
    # value with #base_dir, the base directory cannot be set again.
    def base_dir=(dir)
      raise "Cannot set base directory twice, or after reading its value" if @base_dir
      @base_dir = File.expand_path(dir)
    end

    # :call-seq:
    #   path_to(*names) => path
    #
    # Returns a path from a combination of name, relative to the project's base directory.
    # Essentially, joins all the supplied names and expands the path relative to #base_dir.
    # Symbol arguments are converted to paths by calling the attribute accessor on the project.
    #
    # Keep in mind that all tasks are defined and executed relative to the Buildfile directory,
    # so you want to use #path_to to get the actual path within the project as a matter of practice.
    #
    # For example:
    #   path_to("foo", "bar")
    #   => /home/project1/foo/bar
    #   path_to("/tmp")
    #   => /tmp
    #   path_to(:base_dir, "foo") # same as path_to("foo")
    #   => /home/project1/foo
    def path_to(*names)
      File.expand_path(File.join(names.map { |name| Symbol === name ? send(name) : name.to_s }), base_dir)
    end
    alias :_ :path_to

    # :call-seq:
    #   define(name, properties?) { |project| ... } => project
    #
    # Define a new sub-project within this project. See Buildr#define.
    def define(name, properties = nil, &block)
      Project.define "#{self.name}:#{name}", properties, &block
    end

    # :call-seq:
    #   project(name) => project
    #   project => self
    #
    # Same as Buildr#project. This method is called on a project, so a relative name is
    # sufficient to find a sub-project.
    #
    # When called on a project without a name, returns the project itself. You can use that when
    # setting project properties, for example:
    #   define "foo" do
    #     project.version = "1.0"
    #   end
    def project(*args)
      if Hash === args.last
        options = args.pop
      else
        options = {}
      end
      if args.empty?
        self
      else
        Project.project *(args + [{ :scope=>self.name }.merge(options)])
      end
    end

    # :call-seq:
    #   projects(*names) => projects
    #
    # Same as Buildr#projects. This method is called on a project, so relative names are
    # sufficient to find sub-projects.
    def projects(*args)
      if Hash === args.last
        options = args.pop
      else
        options = {}
      end
      Project.projects *(args + [{ :scope=>self.name }.merge(options)])
    end

    # :call-seq:
    #   file(path) => Task
    #   file(path=>prereqs) => Task
    #   file(path) { |task| ... } => Task
    #
    # Creates and returns a new file task in the project. Similar to calling Rake's
    # file method, but the path is expanded relative to the project's base directory,
    # and the task executes in the project's base directory.
    #
    # For example:
    #   define "foo" do
    #     define "bar" do
    #       file("src") { ... }
    #     end
    #   end
    #
    #   puts project("foo:bar").file("src").to_s
    #   => "/home/foo/bar/src"
    def file(args, &block)
      task_name, deps = Rake.application.resolve_args(args)
      deps = [deps] unless deps.respond_to?(:to_ary)
      Rake::FileTask.define_task(path_to(task_name)=>deps, &block)
    end

    # :call-seq:
    #   task(name) => Task
    #   task(name=>prereqs) => Task
    #   task(name) { |task| ... } => Task
    #
    # Creates and returns a new task in the project. Similar to calling Rake's task
    # method, but prefixes the task name with the project name and executes the task
    # in the project's base directory.
    #
    # For example:
    #   define "foo" do
    #     task "doda"
    #   end
    #
    #   puts project("foo").task("doda").name
    #   => "foo:doda"
    #
    # When called from within the project definition, creates a new task if the task
    # does not already exist. If called from outside the project definition, returns
    # the named task and raises an exception if the task is not defined.
    #
    # As with Rake's task method, calling this method enhances the task with the
    # prerequisites and optional block.
    def task(args, &block)
      task_name, deps = Rake.application.resolve_args(args)
      if task_name =~ /^:/
        Rake.application.instance_eval do
          scope, @scope = @scope, []
          begin
            Rake::Task.define_task(task_name[1..-1]=>deps, &block)
          ensure
            @scope = scope
          end
        end
      elsif Rake.application.current_scope == name.split(":")
        Rake::Task.define_task(task_name=>deps, &block)
      else
        if task = Rake.application.lookup(task_name, name.split(":"))
          deps = [deps] unless deps.respond_to?(:to_ary)
          task.enhance deps, &block
        else
          full_name = "#{name}:#{task_name}"
          raise "You cannot define a project task outside the project definition, and no task #{full_name} defined in the project"
        end
      end
    end

    # :call-seq:
    #   recursive_task(name=>prereqs) { |task| ... }
    #
    # Define a recursive task. A recursive task executes itself and the same task
    # in all the sub-projects.
    def recursive_task(args, &block)
      task_name, deps = Rake.application.resolve_args(args)
      deps = [deps] unless deps.respond_to?(:to_ary)
      task = Buildr.options.parallel ? multitask(task_name) : task(task_name)
      parent.task(task_name).enhance [task] if parent
      task.enhance deps, &block
    end

    def execute() #:nodoc:
      # Reset the namespace, so all tasks are automatically defined in the project's namespace.
      Rake.application.in_namespace(":#{name}") { super }
    end

    def inspect() #:nodoc:
      %Q{project(#{name.inspect})}
    end

  end

  # :call-seq:
  #   define(name, properties?) { |project| ... } => project
  #
  # Defines a new project.
  #
  # The first argument is the project name. Each project must have a unique name.
  # For a sub-project, the actual project name is created by prefixing the parent
  # project's name.
  #
  # The second argument is optional and contains a hash or properties that are set
  # on the project. You can only use properties that are supported by the project
  # definition, e.g. :group and :version. You can also set these properties from the
  # project definition.
  #
  # You pass a block that is executed in the context of the project definition.
  # This block is used to define the project and tasks that are part of the project.
  # Do not perform any work inside the project itself, as it will execute each time
  # the Buildfile is loaded. Instead, use it to create and extend tasks that are
  # related to the project.
  #
  # For example:
  #   define "foo", :version=>"1.0" do
  #
  #     define "bar" do
  #       compile.with "org.apache.axis2:axis2:jar:1.1"
  #     end
  #   end
  #
  #   puts project("foo").version
  #   => "1.0"
  #   puts project("foo:bar").compile.classpath.map(&:to_spec)
  #   => "org.apache.axis2:axis2:jar:1.1"
  #   % buildr build
  #   => Compiling 14 source files in foo:bar
  def define(name, properties = nil, &block) #:yields:project
    Project.define(name, properties, &block)
  end

  # :call-seq:
  #   project(name) => project
  #
  # Returns a project definition.
  #
  # When called from outside a project definition, must reference the project by its
  # full name, e.g. "foo:bar" to access the sub-project "bar" in "foo". When called
  # from inside a project, relative names are sufficient, e.g. <code>project("foo").project("bar")</code>
  # will find the sub-project "bar" in "foo".
  #
  # You cannot reference a project before the project is defined. When working with
  # sub-projects, the project definition is stored by calling #define, and evaluated
  # before a call to the parent project's #define method returns.
  #
  # However, if you call #project with the name of another sub-project, its definition
  # is evaluated immediately. So the returned project definition is always complete,
  # and you can access its definition (e.g. to find files relative to the base directory,
  # or packages created by that project).
  #
  # For example:
  #   define "myapp" do
  #     self.version = "1.1"
  #
  #     define "webapp" do
  #       # webapp is defined first, but beans is evaluated first
  #       compile.with project("beans")
  #       package :war
  #     end
  #
  #     define "beans" do
  #       package :jar
  #     end
  #   end
  #
  #   puts project("myapp:beans").version
  def project(*args)
    Project.project *args
  end

  # :call-seq:
  #   projects(*names) => projects
  #
  # With no arguments, returns a list of all projects defined so far. When called on a project,
  # returns all its sub-projects (direct descendants).
  #
  # With arguments, returns a list of named projects, fails on any name that does not exist.
  # As with #project, you can use relative names when calling this method on a project.
  #
  # Like #project, this method evaluates the definition of each project before returning it.
  # Be advised of circular dependencies.
  #
  # For example:
  #   files = projects.map { |prj| FileList[prj.path_to("src/**/*.java") }.flatten
  #   puts "There are #{files.size} source files in #{projects.size} projects"
  #
  #   puts projects("myapp:beans", "myapp:webapp").map(&:name)
  # Same as:
  #   puts project("myapp").projects.map(&:name)
  def projects(*args)
    Project.projects *args
  end

  # Forces all the projects to be evaluated before executing any other task.
  # If we don't do that, we don't get to have tasks available when running Rake.
  task "buildr:initialize" do
    projects
  end

end