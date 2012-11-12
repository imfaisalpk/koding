@KDApps = {}

class KodingAppsController extends KDController

  escapeFilePath = FSHelper.escapeFilePath

  defaultManifest = (type, name)->
    {profile} = KD.whoami()
    fullName = Encoder.htmlDecode "#{profile.firstName} #{profile.lastName}"
    raw =
      devMode       : yes
      version       : "0.1"
      name          : "#{name or type.capitalize()}"
      identifier    : "com.koding.apps.#{__utils.slugify name or type}"
      path          : "~/Applications/#{name or type.capitalize()}.kdapp"
      homepage      : "#{profile.nickname}.koding.com/#{__utils.slugify name or type}"
      author        : "#{fullName}"
      repository    : "git://github.com/#{profile.nickname}/#{__utils.slugify name or type}.kdapp.git"
      description   : "#{name or type} : a Koding application created with the #{type} template."
      category      : "web-app" # can be web-app, add-on, server-stack, framework, misc
      source        :
        blocks      :
          app       :
            # pre     : ""
            files   : [ "./index.coffee" ]
            # post    : ""
        stylesheets : [ "./resources/style.css" ]
      options       :
        type        : "tab"
      icns          :
        "128"       : "./resources/icon.128.png"

    json = JSON.stringify raw, null, 2

  @manifests = {}


  # #
  # HELPERS
  # #

  getAppPath = (manifest)->

    {profile} = KD.whoami()
    path = if /^~/.test manifest.path then "/Users/#{profile.nickname}#{manifest.path.substr(1)}" else manifest.path
    return path.replace /(\/+)$/, ""

  @getManifestFromPath = getManifestFromPath = (path)->

    folderName = (p for p in path.split("/") when /\.kdapp/.test p)[0]
    app        = null

    return app unless folderName

    for own name, manifest of KodingAppsController.manifests
      do ->
        app = manifest if manifest.path.search(folderName) > -1

    return app

  constructor:->

    super

    @kiteController = @getSingleton('kiteController')

  # #
  # FETCHERS
  # #

  fetchApps:(callback)->

    if KD.isLoggedIn() and not @appStorage?
      @appStorage = new AppStorage 'KodingApps', '1.0'

    if Object.keys(@constructor.manifests).length isnt 0
      callback null, @constructor.manifests
    else
      @fetchAppsFromDb (err, apps)=>
        if err
          @fetchAppsFromFs (err, apps)=>
            if err then callback()
            else
              callback null, apps
        else
          callback? err, apps

  fetchAppsFromFs:(callback)->

    path = "/Users/#{KD.whoami().profile.nickname}/Applications"

    @kiteController.run "ls #{escapeFilePath path} -lpva", (err, response)=>
      if err
        @putAppsToAppStorage {}
        warn err
        callback err
      else
        files = FSHelper.parseLsOutput [path], response
        apps  = []
        stack = []

        files.forEach (file)->
          if /\.kdapp$/.test file.name
            apps.push file

        apps.forEach (app)=>
          stack.push (cb)=>
            manifestFile = if app.type is "folder" then FSHelper.createFileFromPath "#{app.path}/.manifest" else app
            manifestFile.fetchContents (err, response)->
              cb null, response # shadowing the error is intentional here to not to break the results of the stack

        manifests = @constructor.manifests
        async.parallel stack, (err, results)=>
          warn err if err
          results.forEach (rawManifest)->
            if rawManifest
              try
                manifest = JSON.parse rawManifest
                manifests["#{manifest.name}"] = manifest
              catch e
                console.warn "Manifest file is broken", e
          @putAppsToAppStorage manifests
          callback? null, manifests

  fetchAppsFromDb:(callback)->

    @appStorage.fetchStorage (storage)=>

      apps = @appStorage.getValue 'apps'
      shortcuts = @appStorage.getValue 'shortcuts'

      justFetchApps = =>
        if apps and Object.keys(apps).length > 0
          @constructor.manifests = apps
          callback null, apps
        else
          callback new Error "There are no apps in the app storage."

      if not shortcuts
        @putDefaultShortcutsToAppStorage =>
          justFetchApps()
      else
        justFetchApps()

  fetchCompiledApp:(manifest, callback)->

    {name} = manifest
    appPath = getAppPath manifest
    indexJsPath = "#{appPath}/index.js"
    @kiteController.run "cat #{escapeFilePath indexJsPath}", (err, response)=>
      callback err, response

  # #
  # MISC
  # #

  refreshApps:(callback)->

    @constructor.manifests = {}
    KDApps = {}
    @fetchAppsFromFs (err, apps)=>
      @emit "AppsRefreshed", apps
      if not err
        callback? err, apps
      else
        callback err

  removeShortcut:(shortcut, callback)->
    @appStorage.fetchValue 'shortcuts', (shortcuts)=>
      delete shortcuts[shortcut]
      @appStorage.setValue 'shortcuts', shortcuts, (err)=>
        callback err

  putDefaultShortcutsToAppStorage:(callback)->

    shortcuts       =
      Ace           :
        name        : 'Ace'
        type        : 'koding-app'
        icon        : 'icn-ace.png'
        description : 'Code Editor'
        author      : 'Mozilla'
      Terminal      :
        name        : 'Terminal'
        type        : 'koding-app'
        icon        : 'icn-terminal.png'
        description : 'Koding Terminal'
        author      : 'Koding'
        path        : 'WebTerm'
      CodeMirror    :
        name        : 'CodeMirror'
        type        : 'comingsoon'
        icon        : 'icn-codemirror.png'
        description : 'Code Editor'
        author      : 'Marijn Haverbeke'
      yMacs         :
        name        : 'yMacs'
        type        : 'comingsoon'
        icon        : 'icn-ymacs.png'
        description : 'Code Editor'
        author      : 'Mihai Bazon'
      Pixlr         :
        name        : 'Pixlr'
        type        : 'comingsoon'
        icon        : 'icn-pixlr.png'
        description : 'Image Editor'
        author      : 'Autodesk'

    @appStorage.reset()
    @appStorage.setValue 'shortcuts', shortcuts, callback

  putAppsToAppStorage:(apps)->

    @appStorage.setValue 'apps', apps

  defineApp:(name, script)->

    KDApps[name] = script

  getAppScript:(manifest, callback = noop)->

    {name} = manifest

    if KDApps[name]
      callback null, KDApps[name]
    else

      @fetchCompiledApp manifest, (err, script)=>
        if err
          @compileApp name, (err)=>
            if err
              new KDNotificationView type : "mini", title : "There was an error, please try again later!"
              callback err
            else
              callback err, KDApps[name]
        else
          @defineApp name, script
          callback err, KDApps[name]

  # #
  # KITE INTERACTIONS
  # #

  runApp:(manifest, callback)->

    {options, name, devMode} = manifest
    {stylesheets} = manifest.source if manifest.source

    proxifyUrl=(url)->
      "https://api.koding.com/1.0/image.php?url="+ encodeURIComponent(url)

    if stylesheets
      stylesheets.forEach (sheet)->
        if devMode
          $("head #app-#{__utils.slugify name}").remove()
          urlToStyle = "https://#{KD.whoami().profile.nickname}.koding.com/.applications/#{__utils.slugify name}/#{__utils.stripTags sheet}"
          $('head').append "<link id='app-#{__utils.slugify name}' rel='stylesheet' href='#{urlToStyle}'>"
        else
          if /(http)|(:\/\/)/.test sheet
            warn "external sheets cannot be used"
          else
            sheet = sheet.replace /(^\.\/)|(^\/+)/, ""
            $("head #app-#{__utils.slugify name}").remove()
            $('head').append("<link id='app-#{__utils.slugify name}' rel='stylesheet' href='#{KD.appsUri}/#{manifest.authorNick or KD.whoami().profile.nickname}/#{__utils.stripTags name}/latest/#{__utils.stripTags sheet}'>")

    showError = (error)->
      new KDModalView
        title   : "An error occured while running the App!"
        width   : 500
        overlay : yes
        content : """
                  <div class='modalformline'>
                    <h3>#{error.constructor.name}</h3><br/>
                    <pre>#{error.message}</pre>
                  </div>
                  <p class='modalformline'>
                    <cite>Check Console for more details.</cite>
                  </p>
                  """
                  # We may after put a full stck to the output
                  # It looks weird for now.
                  # <pre>#{error.stack}</pre>

      console.warn error.message, error

    @getAppScript manifest, (err, appScript)=>
      if err then warn err
      else
        if options and options.type is "tab"
          mainView = @getSingleton('mainView')
          mainView.mainTabView.showPaneByView
            name         : manifest.name
            hiddenHandle : no
            type         : "application"
          , (appView = new KDView)
          try
            # security please!
            do (appView)->
              appScript = "var appView = KD.instances[\"#{appView.getId()}\"];\n\n"+appScript
              eval appScript
          catch error
            # if not manifest.ignoreWarnings? # GG FIXME
            showError error
          callback?()
          return appView
        else
          try
            # security please!
            do ->
              eval appScript
          catch error
            showError error
          callback?()
          return null

        log "App to run:", name
        callback?()

  addScript:(app, scriptInput, callback)->

    scriptPath = "#{getAppPath(app)}/#{scriptInput}"
    if /^\.\//.test scriptInput
      @kiteController.run "cat #{escapeFilePath scriptPath}", (err, response)=>
        if err then warn err

        if /.coffee$/.test scriptInput
          require ["coffee-script"], (coffee)->
            js = coffee.compile response, { bare : yes }
            callback err, js
        else
          callback err, response
    else
      callback null, scriptInput

  saveCompiledApp:(app, script, callback)->

    @getSingleton("kiteController").run
      method        : "uploadFile"
      withArgs    : {
        path      : escapeFilePath "#{getAppPath app}/index.js"
        contents  : script
      }
    , (err, response)=>
      if err then warn err
      # log response, "App saved!"
      callback?()

  publishApp:(path, callback)->

    if not (KD.checkFlag('app-publisher') or KD.checkFlag('super-admin'))
      err = "You are not authorized to publish apps."
      log err
      callback? err
      return no

    manifest = getManifestFromPath(path)
    appName  = manifest.name

    @getAppScript manifest, (appScript)=>

      manifest        = @constructor.manifests[appName]
      userAppPath     = getAppPath manifest
      options         =
        method        : "publishApp"
        withArgs      :
          version     : manifest.version
          appName     : manifest.name
          userAppPath : userAppPath
          profile     : KD.whoami().profile

      @kiteController.run options, (err, res)=>
        log "app is being published"
        if err
          warn err
          callback? err
        else
          manifest.authorNick = KD.whoami().profile.nickname
          jAppData   =
            title      : manifest.name        or "Application Title"
            body       : manifest.description or "Application description"
            identifier : manifest.identifier  or "com.koding.apps.#{__utils.slugify manifest.name}"
            manifest   : manifest

          appManager.tell "Apps", "createApp", jAppData, (err, app)=>
            if err
              warn err
              callback? err
            else
              log app, "app published"
              appManager.openApplication "Apps", yes, (instance)=>
                @utils.wait 100, instance.feedController.changeActiveSort "meta.modifiedAt"
                callback?()


  approveApp:(app, callback)->

    if not KD.checkFlag('super-admin')
      err = "You are not authorized to approve apps."
      log err
      callback? err
      return no

    options         =
      method        : "approveApp"
      withArgs      :
        version     : app.manifest.version
        appName     : app.manifest.name
        authorNick  : app.manifest.authorNick

    @kiteController.run options, (err, res)=>
      log "app is being approved"
      if err
        warn err
        callback? err
      else
        log app, "app approved"
        callback?()

  # We will move that to Server-Side GG

  compileApp:(name, callback)->

    kallback = (app)=>

      return warn "#{name}: No such app!" unless app

      {source}      = app
      {blocks}      = source
      {nickname}    = KD.whoami().profile
      orderedBlocks = []
      blockStrings  = []
      asyncStack    = []

      for blockName, blockOptions of blocks
        blockOptions.name = blockName
        if blockOptions.order? and not isNaN(order = parseInt(blockOptions.order, 10))
          orderedBlocks[order] = blockOptions
        else
          orderedBlocks.push blockOptions

      if app.devMode
        appResourceRoot = "/Users/#{nickname}/Sites/#{nickname}.koding.com/website/.applications"
        appDevModePath  = "#{appResourceRoot}/#{__utils.slugify name}"

        asyncStack.push (cb)=>
          @kiteController.run "rm -rf #{escapeFilePath appDevModePath}", =>
            @kiteController.run "test -d #{appResourceRoot} || mkdir #{appResourceRoot}", =>
              @kiteController.run "ln -s #{escapeFilePath getAppPath app} #{escapeFilePath appDevModePath}", -> cb()

      orderedBlocks.forEach (block)=>

        if block.pre
          asyncStack.push (cb)=> @addScript app, block.pre, cb

        if block.files
          {files} = block
          files.forEach (file, index)=>
            if "object" is typeof file
              for fileName, fileExtras of file
                do =>
                  # log fileExtras.pre  if fileExtras.pre
                  if fileExtras.pre
                    asyncStack.push (cb)=> @addScript app, fileExtras.pre, cb
                  # log fileName
                  asyncStack.push (cb)=> @addScript app, fileName, cb
                  # log fileExtras.post if fileExtras.post
                  if fileExtras.post
                    asyncStack.push (cb)=> @addScript app, fileExtras.post, cb
            else
              # log file
              asyncStack.push (cb)=> @addScript app, file, cb
        # log block.post if block.post
        if block.post
          asyncStack.push (cb)=> @addScript app, block.post, cb

      async.parallel asyncStack, (error, result)=>

        _final = "(function() {\n\n/* KDAPP STARTS */"
        result.forEach (output)=>
          _final += "\n\n/* BLOCK STARTS */\n\n"
          _final += "#{if output then output else '//couldn\'t compile the hunk!'}"
          _final += "\n\n/* BLOCK ENDS */\n\n"
        _final += "/* KDAPP ENDS */\n\n}).call();"

        _final = @defineApp app.name, _final
        @saveCompiledApp app, _final, =>
          callback?()

    unless @constructor.manifests[name]
      @fetchApps (err, apps)=> kallback apps[name]
    else
      @kiteController.run "stat #{escapeFilePath getAppPath @constructor.manifests[name]}", (err)=>
        if err
          new KDNotificationView
            title    : "App list is out-dated, refreshing apps..."
            duration : 2000
          @refreshApps noop
        else
          kallback @constructor.manifests[name]

  installApp:(app, version='latest', callback)->

    @fetchApps (err, manifests = {})=>
      if err
        warn err
        new KDNotificationView type : "mini", title : "There was an error, please try again later!"
        callback? err
      else
        # log manifests
        if app.title in Object.keys(manifests)
          new KDNotificationView type : "mini", title : "App is already installed!"
          callback? msg : "App is already installed!"
        else
          # log "installing the app: #{app.title}"
          if not app.approved and not KD.checkFlag 'super-admin'
            err = "This app is not approved, installation cancelled."
            log err
            callback? err
          else
            app.fetchCreator (err, acc)=>
              # log err, acc, ">>>>"
              if err
                callback? err
              else
                options =
                  method        : "installApp"
                  withArgs      :
                    owner       : acc.profile.nickname
                    appPath     : getAppPath app.manifest
                    appName     : app.manifest.name
                    version     : version
                # log "asking kite to install", options
                @kiteController.run options, (err, res)=>
                  log "Kite response: ", err, res
                  if err then warn err
                  else
                    app.install (err)=>
                      log err if err
                      # log callback
                      # This doesnt work :#
                      appManager.openApplication "StartTab"
                      @refreshApps()
                      # callback?()

  # #
  # MAKE NEW APP
  # #

  newAppModal = null

  makeNewApp:(callback)->

    return callback? yes if newAppModal

    newAppModal = new KDModalViewWithForms
      title                       : "Create a new Application"
      content                     : "<div class='modalformline'>Please select the application type you want to start with.</div>"
      overlay                     : yes
      width                       : 400
      height                      : "auto"
      tabs                        :
        navigable                 : yes
        forms                     :
          form                    :
            buttons               :
              Create              :
                cssClass          : "modal-clean-gray"
                loader            :
                  color           : "#444444"
                  diameter        : 12
                callback          : =>
                  unless newAppModal.modalTabs.forms.form.inputs.name.validate()
                    newAppModal.modalTabs.forms.form.buttons.Create.hideLoader()
                    return
                  name        = newAppModal.modalTabs.forms.form.inputs.name.getValue()
                  type        = newAppModal.modalTabs.forms.form.inputs.type.getValue()
                  name        = name.replace(/[^a-zA-Z0-9\/\-.]/g, '') if name
                  manifestStr = defaultManifest type, name
                  manifest    = JSON.parse manifestStr
                  appPath     = getAppPath manifest

                  FSItem.doesExist appPath, (err, exists)=>
                    if exists
                      newAppModal.modalTabs.forms.form.buttons.Create.hideLoader()
                      new KDNotificationView
                        type      : "mini"
                        cssClass  : "error"
                        title     : "App folder with that name is already exists, please choose a new name."
                        duration  : 3000
                    else
                      @prepareApplication {isBlank : type is "blank", name}, (err, response)=>
                        callback? err
                        newAppModal.modalTabs.forms.form.buttons.Create.hideLoader()
                        newAppModal.destroy()
            fields                :
              type                :
                label             : "Type"
                itemClass         : KDSelectBox
                type              : "select"
                name              : "type"
                defaultValue      : "sample"
                selectOptions     : [
                  { title : "Sample Application", value : "sample" }
                  { title : "Blank Application",  value : "blank"  }
                ]
              name                :
                label             : "Name:"
                name              : "name"
                placeholder       : "name your application..."
                validate          :
                  rules           :
                    regExp        : /^[a-z\d]+([-][a-z\d]+)*$/i
                  messages        :
                    regExp        : "For Application name only lowercase letters and numbers are allowed!"

    newAppModal.once "KDObjectWillBeDestroyed", ->
      newAppModal = null
      callback? yes

  prepareApplication:({isBlank, name}, callback)->

    type        = if isBlank then "blank" else "sample"
    name        = if name is "" then null else name
    name        = name.replace(/[^a-zA-Z0-9\/\-.]/g, '') if name
    manifestStr = defaultManifest type, name
    manifest    = JSON.parse manifestStr
    appPath     = getAppPath manifest
    # log manifestStr

    FSItem.create appPath, "folder", (err, fsFolder)=>
      if err then warn err
      else
        stack = []
        today = new Date().format('yyyy-mm-dd')
        {profile} = KD.whoami()
        fullName = Encoder.htmlDecode "#{profile.firstName} #{profile.lastName}"

        stack.push (cb)=>
          @kiteController.run
            method      : "uploadFile"
            withArgs    :
              path      : escapeFilePath "#{fsFolder.path}/.manifest"
              contents  : manifestStr
          , cb

        # if isBlank
        #   stack.push (cb)=>
        #     @kiteController.run
        #       method      : "uploadFile"
        #       withArgs    :
        #         path      : escapeFilePath "#{fsFolder.path}/index.coffee"
        #         contents  : """
        #                       do->

        #                     """
        #     , cb

        stack.push (cb)=>
          @kiteController.run
            method      : "uploadFile"
            withArgs    :
              path      : escapeFilePath "#{fsFolder.path}/ChangeLog"
              contents  : """
                              #{today} #{fullName} <@#{profile.nickname}>

                                  * #{name} (index.coffee): Application created.
                          """
          , cb

        # Copy default app files (app Skeleton)
        stack.push (cb)=>
          @kiteController.run
            kiteName  : "applications"
            method    : "copyAppSkeleton"
            withArgs  :
              type    : if isBlank then "blank" else "sample"
              appPath : appPath
            , cb

        async.parallel stack, (error, result) =>
          if err then warn err
          @emit "aNewAppCreated" if not err
          callback? err, result

  # #
  # FORK / CLONE APP
  # #

  downloadAppSource:(path, callback)->

    @fetchApps =>
      manifest = getManifestFromPath path

      unless manifest
        callback new KDNotificationView type : "mini", title : "Please refresh your apps and try again!"
        return

      @kiteController.run
        method      : "downloadApp"
        withArgs    :
          owner     : manifest.authorNick
          appName   : manifest.name
          appPath   : getAppPath manifest
          version   : manifest.version
      , (err, res)=>
        if err
          warn err
          callback? err
        else
          callback? null


  cloneApp:(path, callback)->

    @fetchApps (err, manifests = {})=>
      if err
        warn err
        new KDNotificationView type : "mini", title : "There was an error, please try again later!"
        callback? err
      else
        manifest = getManifestFromPath path

        {repo} = manifest

        if /^git/.test repo      then repoType = "git"
        else if /^svn/.test repo then repoType = "svn"
        else if /^hg/.test repo  then repoType = "hg"
        else
          err = "Unsupported repository specified, quitting!"
          new KDNotificationView type : "mini", title : err
          callback? err
          return no

        appPath = "/Users/#{KD.whoami().profile.nickname}/Applications/#{manifest.name}.kdapp"
        appBackupPath = "#{appPath}.old#{@utils.getRandomNumber 9999}"

        @kiteController.run "mv #{escapeFilePath appPath} #{escapeFilePath appBackupPath}" , (err, response)->
          if err then warn err
          @kiteController.run "#{forkRepoCommandMap()[repoType]} #{repo} #{escapeFilePath getAppPath manifest}", (err, response)->
            if err then warn err
            else
              log response, "App cloned!"
            callback? err, response
