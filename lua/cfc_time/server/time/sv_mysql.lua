require( "mysqloo" )

-- TODO: Make a config module that will load the connection settings properly
-- TODO: Load/Set the realm
CFCTime.SQL.database = mysqloo.connect( "host", "username", "password", "cfc_time" )
CFCTime.SQL.preparedQueries = {}

local noop = function()end

function CFCTime.SQL:InitTransaction()
    local transaction = self.database:createTransaction()

    transaction.onError = function( _, err )
        self.Logger:error( err )
    end

    return transaction
end

function CFCTime.SQL:InitQuery( sql )
    local query = self.database:query( sql )

    query.onError = function( _, ... )
        CFCTime.Logger:error( ... )
    end

    return query
end

function CFCTime.SQL:CreateUsersQuery()
    local createUsers = [[
        CREATE TABLE IF NOT EXISTS users(
            steam_id VARCHAR(20) PRIMARY KEY
        );
    ]]

    return self.database:query( createUsers )
end

function CFCTime.SQL:CreateSessionsQuery()
    local createSessions = [[
        CREATE TABLE IF NOT EXISTS sessions(
            id       INT                  PRIMARY KEY AUTO_INCREMENT,
            realm    VARCHAR(10)          NOT NULL,
            user_id  VARCHAR(20)          NOT NULL,
            start    INT         UNSIGNED NOT NULL,
            end      INT         UNSIGNED NOT NULL,
            duration MEDIUMINT   UNSIGNED NOT NULL DEFAULT 0,
            FOREIGN KEY (user_id) REFERENCES users (steam_id) ON DELETE CASCADE
        )
    ]]

    return self.database:query( createSessions )
end

function CFCTime.SQL:EndTimeCleanupQuery()
    local cleanupMissingEndTimes = string.format( [[
        UPDATE sessions
        SET end = start + duration
        WHERE end IS NULL
        AND realm = %s
    ]], self.realm )

    return self.database:query( cleanupMissingEndTimes )
end

function CFCTime.SQL:AddPreparedStatement( name, query )
    local statement = self.database:prepare( query )

    statement.onError = function( _, err, sql )
        CFCTime.Logger:error( err, sql )
    end

    self.preparedStatements[name] = statement
end

function CFCTime.SQL:PrepareStatements()
    CFCTime.Logger:info( "Constructing prepared statements..." )

    local realm = self.realm

    local newUser = "INSERT IGNORE INTO users (steam_id) VALUES(?)"

    local newSession = string.format( [[
        INSERT INTO sessions (user_id, start, realm) VALUES(?, ?, %s)
    ]], realm )

    local totalTime = string.format( [[
        SELECT SUM(duration)
        FROM sessions
        WHERE user_id = ?
        AND realm = %s
    ]], realm )

    self:AddPreparedStatement( "newUser", newUser )
    self:AddPreparedStatement( "newSession", newSession )
    self:AddPreparedStatement( "totalTime", totalTime )
end

function CFCTime.SQL:Prepare( statementName, onSuccess, ... )
    local query = self.preparedStatements[statementName]
    query:clearParameters()

    for k, v in pairs( { ... } ) do
        if isnumber( v ) then
            query:setNumber( k, v )
        elseif isstring( v ) then
            query:setString( k, v )
        elseif isbool( v ) then
            query:setBoolean( k, v )
        else
            error( "Wrong data type passed to Prepare statement!: " .. v )
        end
    end

    query.onSuccess = onSuccess or noop

    return query
end

function CFCTime.SQL.database:onConnected()
    CFCTime.Logger:info( "DB successfully connected! Beginning init..." )

    local transaction = CFCTime.SQL:InitTransaction()

    transaction:addQuery( CFCTime.SQL:CreateUsersQuery() )
    transaction:addQuery( CFCTime.SQL:CreateSessionsQuery() )
    transaction:addQuery( CFCTime.SQL:EndTimeCleanupQuery() )

    transaction.onSuccess = function()
        CFCTime.SQL:PrepareStatements()
    end

    transaction:start()
end

function CFCTime.SQL.database:onConnectionFailed( _, err )
    CFCTime.Logger:error( "Failed to connect to database!" )
    CFCTime.Logger:fatal( err )
end

hook.Add( "PostGamemodeLoaded", "CFC_Time_DBInit", function()
    CFCTime.Logger:log( "Gamemoded loaded, beginning database init..." )
    CFCTime.SQL.database:connect()
end )

function CFCTime.SQL:BuildSessionUpdate( data, id )
    local updateSection = "UPDATE sessions "
    local setSection = "SET "
    local whereSection = "WHERE id = " .. id
    local whereSection = string.format(
        "WHERE id = %s AND realm = %s",
        id, self.realm
    )

    local count = table.Count( data )
    local idx = 1
    for k, v in pairs( data ) do
        local newSet = k .. " = " .. v
        
        if idx ~= count then
            -- Add a comma if it isn't the last one
            newSet = newSet .. ","
        else
            -- Add a space if it's the last one
            newSet = newSet .. " "
        end
        
        setSection = setSection .. newSet
        idx = idx + 1
    end

    local query = updateSection .. setSection .. whereSection

    return query
end

--[ API Begins Here ]--

function CFCTime.SQL:UpdateBatch( batchData )
    local transaction = CFCTime.SQL:InitTransaction()

    for sessionId, data in pairs( batchData ) do
        local updateStr = self:BuildSessionUpdate( data, sessionId )
        local query = self.database:query( updateStr )

        transaction:addQuery( query )
    end

    transaction:start()
end

function CFCTime.SQL:GetTotalTime( steamId, cb )
    local onSuccess = function( _, data )
        cb( data )
    end

    local query = self:Prepare( "totalTime", onSuccess, steamId )

    query:start()
end

function CFCTime.SQL:NewUserSession( steamId, sessionStart, cb )
    local transaction = CFCTime.SQL:InitTransaction()

    local newUser = self:Prepare( "newUser", nil, steamId )
    local newSession = self:Prepare( "newSession", nil, steamId, sessionStart )

    transaction:addQuery( newUser )
    transaction:addQuery( newSession )

    transaction.onSuccess = function( _, data )
        cb( data )
    end

    transaction:start()
end
