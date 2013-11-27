/* Copyright 2009-2013 Remus Rusanu
*
*   Licensed under the Apache License, Version 2.0 (the "License");
*   you may not use this file except in compliance with the License.
*   You may obtain a copy of the License at
*
*       http://www.apache.org/licenses/LICENSE-2.0
*
*   Unless required by applicable law or agreed to in writing, software
*   distributed under the License is distributed on an "AS IS" BASIS,
*   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
*   See the License for the specific language governing permissions and
*   limitations under the License.
*/

create table [AsyncExecResults] (
 [token] uniqueidentifier primary key
 , [submit_time] datetime not null
 , [start_time] datetime null
 , [finish_time] datetime null
 , [error_number] int null
 , [error_message] nvarchar(2048) null);
go

create queue [AsyncExecQueue];
go

create service [AsyncExecService] on queue [AsyncExecQueue] ([DEFAULT]);
GO

-- Dynamic SQL helper procedure
-- Extracts the parameters from the message body
-- Creates the invocation Transact-SQL batch
-- Invokes the dynmic SQL batch
create procedure [usp_procedureInvokeHelper] (@x xml)
as
begin
    set nocount on;

    declare @stmt nvarchar(max)
        , @stmtDeclarations nvarchar(max)
        , @stmtValues nvarchar(max)
        , @i int
        , @countParams int
        , @namedParams nvarchar(max)
        , @paramName sysname
        , @paramType sysname
        , @paramPrecision int
        , @paramScale int
        , @paramLength int
        , @paramTypeFull nvarchar(300)
        , @comma nchar(1)

    select @i = 0
        , @stmtDeclarations = N''
        , @stmtValues = N''
        , @namedParams = N''
        , @comma = N''

    declare crsParam cursor forward_only static read_only for
        select x.value(N'@Name', N'sysname')
            , x.value(N'@BaseType', N'sysname')
            , x.value(N'@Precision', N'int')
            , x.value(N'@Scale', N'int')
            , x.value(N'@MaxLength', N'int')
        from @x.nodes(N'//procedure/parameters/parameter') t(x);
    open crsParam;

    fetch next from crsParam into @paramName
        , @paramType
        , @paramPrecision
        , @paramScale
        , @paramLength;
    while (@@fetch_status = 0)
    begin
        select @i = @i + 1;

        select @paramTypeFull = @paramType +
            case
            when @paramType in (N'varchar'
                , N'nvarchar'
                , N'varbinary'
                , N'char'
                , N'nchar'
                , N'binary') then
                N'(' + cast(@paramLength as nvarchar(5)) + N')'
            when @paramType in (N'numeric') then
                N'(' + cast(@paramPrecision as nvarchar(10)) + N',' +
                cast(@paramScale as nvarchar(10))+ N')'
            else N''
            end;

        -- Some basic sanity check on the input XML
        if (@paramName is NULL
            or @paramType is NULL
            or @paramTypeFull is NULL
            or charindex(N'''', @paramName) > 0
            or charindex(N'''', @paramTypeFull) > 0)
            raiserror(N'Incorrect parameter attributes %i: %s:%s %i:%i:%i'
                , 16, 10, @i, @paramName, @paramType
                , @paramPrecision, @paramScale, @paramLength);

        select @stmtDeclarations = @stmtDeclarations + N'
declare @pt' + cast(@i as varchar(3)) + N' ' + @paramTypeFull
            , @stmtValues = @stmtValues + N'
select @pt' + cast(@i as varchar(3)) + N'=@x.value(
    N''(//procedure/parameters/parameter)[' + cast(@i as varchar(3))
                + N']'', N''' + @paramTypeFull + ''');'
            , @namedParams = @namedParams + @comma + @paramName
                + N'=@pt' + cast(@i as varchar(3));

        select @comma = N',';

        fetch next from crsParam into @paramName
            , @paramType
            , @paramPrecision
            , @paramScale
            , @paramLength;
    end

    close crsParam;
    deallocate crsParam;        

    select @stmt = @stmtDeclarations + @stmtValues + N'
exec ' + quotename(@x.value(N'(//procedure/name)[1]', N'sysname'));

    if (@namedParams != N'')
        select @stmt = @stmt + N' ' + @namedParams;

    exec sp_executesql @stmt, N'@x xml', @x;
end
go

create procedure usp_AsyncExecActivated
as
begin
    set nocount on;
    declare @h uniqueidentifier
        , @messageTypeName sysname
        , @messageBody varbinary(max)
        , @xmlBody xml
        , @startTime datetime
        , @finishTime datetime
        , @execErrorNumber int
        , @execErrorMessage nvarchar(2048)
        , @xactState smallint
        , @token uniqueidentifier;

    begin transaction;
    begin try;
        receive top(1)
            @h = [conversation_handle]
            , @messageTypeName = [message_type_name]
            , @messageBody = [message_body]
            from [AsyncExecQueue];
        if (@h is not null)
        begin
            if (@messageTypeName = N'DEFAULT')
            begin
                -- The DEFAULT message type is a procedure invocation.
                --
                select @xmlBody = CAST(@messageBody as xml);

                save transaction usp_AsyncExec_procedure;
                select @startTime = GETUTCDATE();
                begin try
                    exec [usp_procedureInvokeHelper] @xmlBody;
                end try
                begin catch
                -- This catch block tries to deal with failures of the procedure execution
                -- If possible it rolls back to the savepoint created earlier, allowing
                -- the activated procedure to continue. If the executed procedure
                -- raises an error with severity 16 or higher, it will doom the transaction
                -- and thus rollback the RECEIVE. Such case will be a poison message,
                -- resulting in the queue disabling.
                --
                select @execErrorNumber = ERROR_NUMBER(),
                    @execErrorMessage = ERROR_MESSAGE(),
                    @xactState = XACT_STATE();
                if (@xactState = -1)
                begin
                    rollback;
                    raiserror(N'Unrecoverable error in procedure: %i: %s', 16, 10,
                        @execErrorNumber, @execErrorMessage);
                end
                else if (@xactState = 1)
                begin
                    rollback transaction usp_AsyncExec_procedure;
                end
                end catch

                select @finishTime = GETUTCDATE();
                select @token = [conversation_id]
                    from sys.conversation_endpoints
                    where [conversation_handle] = @h;
                if (@token is null)
                begin
                    raiserror(N'Internal consistency error: conversation not found', 16, 20);
                end
                update [AsyncExecResults] set
                    [start_time] = @starttime
                    , [finish_time] = @finishTime
                    , [error_number] = @execErrorNumber
                    , [error_message] = @execErrorMessage
                    where [token] = @token;
                if (0 = @@ROWCOUNT)
                begin
                    raiserror(N'Internal consistency error: token not found', 16, 30);
                end
                end conversation @h;
            end
            else if (@messageTypeName = N'http://schemas.microsoft.com/SQL/ServiceBroker/EndDialog')
            begin
                end conversation @h;
            end
            else if (@messageTypeName = N'http://schemas.microsoft.com/SQL/ServiceBroker/Error')
            begin
                declare @errorNumber int
                    , @errorMessage nvarchar(4000);
                select @xmlBody = CAST(@messageBody as xml);
                with xmlnamespaces (DEFAULT N'http://schemas.microsoft.com/SQL/ServiceBroker/Error')
                select @errorNumber = @xmlBody.value ('(/Error/Code)[1]', 'INT'),
                    @errorMessage = @xmlBody.value ('(/Error/Description)[1]', 'NVARCHAR(4000)');
                -- Update the request with the received error
                select @token = [conversation_id]
                    from sys.conversation_endpoints
                    where [conversation_handle] = @h;
                update [AsyncExecResults] set
                    [error_number] = @errorNumber
                    , [error_message] = @errorMessage
                    where [token] = @token;
                end conversation @h;
             end
           else
           begin
                raiserror(N'Received unexpected message type: %s', 16, 50, @messageTypeName);
           end
        end
        commit;
    end try
    begin catch
        declare @error int
         , @message nvarchar(2048);
        select @error = ERROR_NUMBER()
            , @message = ERROR_MESSAGE()
            , @xactState = XACT_STATE();
        if (@xactState <> 0)
        begin
         rollback;
        end;
        raiserror(N'Error: %i, %s', 1, 60,  @error, @message) with log;
    end catch
end
go

alter queue [AsyncExecQueue]
    with activation (
    procedure_name = [usp_AsyncExecActivated]
    , max_queue_readers = 1
    , execute as owner
    , status = on);
go

-- Helper function to create the XML element
-- for a passed in parameter
create function [dbo].[fn_DescribeSqlVariant] (
 @p sql_variant
 , @n sysname)
returns xml
with schemabinding
as
begin
 return (
 select @n as [@Name]
  , sql_variant_property(@p, 'BaseType') as [@BaseType]
  , sql_variant_property(@p, 'Precision') as [@Precision]
  , sql_variant_property(@p, 'Scale') as [@Scale]
  , sql_variant_property(@p, 'MaxLength') as [@MaxLength]
  , @p
  for xml path('parameter'), type)
end
GO

-- Invocation wrapper. Accepts arbitrary
-- named parameetrs to be passed to the
-- background procedure
create procedure [usp_AsyncExecInvoke]
    @procedureName sysname
    , @p1 sql_variant = NULL, @n1 sysname = NULL
    , @p2 sql_variant = NULL, @n2 sysname = NULL
    , @p3 sql_variant = NULL, @n3 sysname = NULL
    , @p4 sql_variant = NULL, @n4 sysname = NULL
    , @p5 sql_variant = NULL, @n5 sysname = NULL
    , @token uniqueidentifier output
as
begin
    declare @h uniqueidentifier
     , @xmlBody xml
        , @trancount int;
    set nocount on;

 set @trancount = @@trancount;
    if @trancount = 0
        begin transaction
    else
        save transaction usp_AsyncExecInvoke;
    begin try
        begin dialog conversation @h
            from service [AsyncExecService]
            to service N'AsyncExecService', 'current database'
            with encryption = off;
        select @token = [conversation_id]
            from sys.conversation_endpoints
            where [conversation_handle] = @h;

        select @xmlBody = (
            select @procedureName as [name]
            , (select * from (
                select [dbo].[fn_DescribeSqlVariant] (@p1, @n1) AS [*]
                    WHERE @p1 IS NOT NULL
                union all select [dbo].[fn_DescribeSqlVariant] (@p2, @n2) AS [*]
                    WHERE @p2 IS NOT NULL
                union all select [dbo].[fn_DescribeSqlVariant] (@p3, @n3) AS [*]
                    WHERE @p3 IS NOT NULL
                union all select [dbo].[fn_DescribeSqlVariant] (@p4, @n4) AS [*]
                    WHERE @p4 IS NOT NULL
                union all select [dbo].[fn_DescribeSqlVariant] (@p5, @n5) AS [*]
                    WHERE @p5 IS NOT NULL
                ) as p for xml path(''), type
            ) as [parameters]
            for xml path('procedure'), type);
        send on conversation @h (@xmlBody);
        insert into [AsyncExecResults]
            ([token], [submit_time])
            values
            (@token, getutcdate());
    if @trancount = 0
        commit;
    end try
    begin catch
        declare @error int
            , @message nvarchar(2048)
            , @xactState smallint;
        select @error = ERROR_NUMBER()
            , @message = ERROR_MESSAGE()
            , @xactState = XACT_STATE();
        if @xactState = -1
            rollback;
        if @xactState = 1 and @trancount = 0
            rollback
        if @xactState = 1 and @trancount > 0
            rollback transaction usp_my_procedure_name;

        raiserror(N'Error: %i, %s', 16, 1, @error, @message);
    end catch
end
go