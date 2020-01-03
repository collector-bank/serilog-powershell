Set-StrictMode -v latest
$ErrorActionPreference = "Stop"

function Main()
{
    if (!$env:eventhubconnstr)
    {
        throw ("Missing environment variable: eventhubconnstr")
    }

    if ($env:serilogteam -and $env:serilogdepartment)
    {
        $global:logger = Get-Logging $env:eventhubconnstr $env:serilogteam $env:serilogdepartment
    }
    else
    {
        $global:logger = Get-Logging $env:eventhubconnstr
    }
}

function Get-Logging([string] $connstr, [string] $team, [string] $department)
{
$csharpcode = 'using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using Serilog.Events;

public class ScalarValueTypeSuffixJsonFormatter : Serilog.Formatting.Json.JsonFormatter
{
    private readonly Dictionary<Type, string> _suffixes = new Dictionary<Type, string>
    {
        [typeof(bool)] = "_b",

        [typeof(byte)] = "_i",
        [typeof(sbyte)] = "_i",
        [typeof(short)] = "_i",
        [typeof(ushort)] = "_i",
        [typeof(int)] = "_i",
        [typeof(uint)] = "_i",
        [typeof(long)] = "_i",
        [typeof(ulong)] = "_i",

        [typeof(float)] = "_d",
        [typeof(double)] = "_d",
        [typeof(decimal)] = "_d",

        [typeof(DateTime)] = "_t",
        [typeof(DateTimeOffset)] = "_t",
        [typeof(TimeSpan)] = "_ts",

        [typeof(string)] = "_s",
    };

    public ScalarValueTypeSuffixJsonFormatter(string closingDelimiter = null, bool renderMessage = true, IFormatProvider formatProvider = null)
        : base(closingDelimiter, renderMessage, formatProvider)
    {
    }

    public void AddSuffix(Type type, string suffix)
    {
        _suffixes[type] = suffix;
    }

    [Obsolete]
    protected override void WriteJsonProperty(string name, object value, ref string precedingDelimiter, TextWriter output)
    {
        base.WriteJsonProperty(DotEscapeFieldName(name + GetSuffix(value)), value, ref precedingDelimiter, output);
    }

    [Obsolete]
    protected override void WriteDictionary(IReadOnlyDictionary<ScalarValue, LogEventPropertyValue> elements, TextWriter output)
    {
        var dictionary = elements.ToDictionary(
            pair => new ScalarValue(DotEscapeFieldName(pair.Key.Value + GetSuffix(pair.Value))),
            pair => pair.Value);

        var readOnlyDictionary = new ReadOnlyDictionary<ScalarValue, LogEventPropertyValue>(dictionary);

        base.WriteDictionary(readOnlyDictionary, output);
    }

    protected virtual string DotEscapeFieldName(string value)
    {
        return value?.Replace(''.'', ''/'');
    }

    private string GetSuffix(object value)
    {
        if (value is ScalarValue scalarValue)
        {
            if (scalarValue.Value != null && _suffixes.ContainsKey(scalarValue.Value.GetType()))
                return _suffixes[scalarValue.Value.GetType()];
            return _suffixes[typeof(string)];
        }

        return string.Empty;
    }
}'

    [string] $assembliesfolder = Join-Path (pwd).Path "log_to_eventhub_assemblies"

    Get-Dependencies $assembliesfolder

    Add-Type $csharpcode -ReferencedAssemblies (Join-Path $assembliesfolder "Serilog.dll"),(Join-Path $assembliesfolder "Serilog.Formatting.Compact.dll"),"System.Linq","netstandard","System.Runtime.Extensions","System.Runtime","System.Collections","System.ObjectModel"

    if ($team -and $department)
    {
$enrichercode = 'using System;
using System.Collections.Generic;

using global::Serilog.Core;
using global::Serilog.Events;

public class AuthorEnricher : ILogEventEnricher
{
    private readonly IDictionary<string, string> _dictionary;

    public AuthorEnricher(string team, string department)
    {
        _dictionary = new Dictionary<string, string> { ["Team"] = team, ["Department"] = department };
    }

    public void Enrich(LogEvent logEvent, ILogEventPropertyFactory propertyFactory)
    {
        logEvent.AddPropertyIfAbsent(propertyFactory.CreateProperty("Author", _dictionary, destructureObjects: true));
    }
}'


        Add-Type $enrichercode -ReferencedAssemblies (Join-Path $assembliesfolder "Serilog.dll"),"System.Collections","netstandard"

        $logger = ([Serilog.LoggerConfiguration]::new()).Enrich.With(([AuthorEnricher]::new($team, $department))).WriteTo.Sink([Serilog.Sinks.AzureEventHub.AzureEventHubSink]::new(([Microsoft.Azure.EventHubs.EventHubClient]::CreateFromConnectionString($connstr)),([ScalarValueTypeSuffixJsonFormatter]::new()))).CreateLogger()
    }
    else
    {
        $logger = ([Serilog.LoggerConfiguration]::new()).WriteTo.Sink([Serilog.Sinks.AzureEventHub.AzureEventHubSink]::new(([Microsoft.Azure.EventHubs.EventHubClient]::CreateFromConnectionString($connstr)),([ScalarValueTypeSuffixJsonFormatter]::new()))).CreateLogger()
    }

    return $logger
}

function Get-Dependencies([string] $assembliesfolder)
{
    [string[]] $nugets = `
        "Microsoft.Azure.Amqp",
        "Microsoft.Azure.EventHubs",
        "Serilog",
        "Serilog.Formatting.Compact",
        "Serilog.Sinks.AzureEventHub",
        "Serilog.Sinks.PeriodicBatching"

    [string[]] $dllfiles = @($nugets | % { Get-Nuget $_ $assembliesfolder })
    foreach ($dllfile in $dllfiles)
    {
        Write-Host ("Loading: '" + $dllfile + "'") -f Green
        Import-Module $dllfile
    }
}

function Get-Nuget([string] $packagename, [string] $assembliesfolder)
{
    if (!(Test-Path $assembliesfolder))
    {
        Write-Host ("Creating folder: '" + $assembliesfolder + "'") -f Green
        md $assembliesfolder | Out-Null
    }

    [string] $dllfile = Join-Path $assembliesfolder ($packagename + ".dll")
    if (Test-Path $dllfile)
    {
        Write-Host ("File already downloaded: '" + $dllfile + "'") -f Green
        return $dllfile
    }

    [string] $url = "https://www.nuget.org/packages/" + $packagename

    Write-Host ("Downloading page: '" + $url + "'") -f Green
    [string[]] $linkrows = @(((Invoke-WebRequest $url).Content.Split("`n")) | ? { $_.Contains("Download package") })
    if ($linkrows.Count -lt 1)
    {
        Write-Host ("Couldn't find any download link: '" + $url + "'") -f Yellow
        return
    }
    if ($linkrows.Count -gt 1)
    {
        Write-Host ("Couldn't find any distinct download link: '" + $url + "'") -f Yellow
        return
    }
    [int] $start = $linkrows[0].IndexOf('"')
    if ($start -eq -1)
    {
        Write-Host ("Malformed download link: '" + $linkrows[0] + "'") -f Yellow
        return
    }
    $start++
    [int] $end = $linkrows[0].IndexOf('"', $start)
    if ($end -eq -1)
    {
        Write-Host ("Malformed download link: '" + $linkrows[0] + "'") -f Yellow
        return
    }

    [string] $downloadLink = $linkrows[0].Substring($start, $end-$start)

    [string] $nugetfile = Join-Path $assembliesfolder ($packagename + ".nupkg")

    if (Test-Path $nugetfile)
    {
        Write-Host ("Deleting file: '" + $nugetfile + "'") -f Green
        del $nugetfile
    }

    Write-Host ("Downloading file: '" + $downloadLink + "' -> '" + $nugetfile + "'") -f Green
    Invoke-WebRequest $downloadLink -OutFile $nugetfile

    if (!(Test-Path $nugetfile) -or (dir $nugetfile).Length -lt 1kb)
    {
        Write-Host ("Couldn't download file.") -f Yellow
        return
    }

    [string] $packagefolder = Join-Path $assembliesfolder $packagename
    if (Test-Path $packagefolder)
    {
        Write-Host ("Deleting folder: '" + $packagefolder + "'") -f Green
        rd -Recurse -Force $packagefolder
    }

    Write-Host ("Extracting: '" + $nugetfile + "' -> '" + $packagefolder + "'") -f Green
    Expand-Archive $nugetfile -DestinationPath $packagefolder

    if (Test-Path $nugetfile)
    {
        Write-Host ("Deleting file: '" + $nugetfile + "'") -f Green
        del $nugetfile
    }

    dir -Directory $assembliesfolder | ? { Test-Path (Join-Path $_.FullName "lib" "netstandard*" "*.dll") } | % {
        dir (Join-Path $_.FullName "lib" "netstandard*" "*.dll") | Sort-Object -Bottom 1 | % {
            [string] $nugetdllfile = $_.FullName
            Write-Host ("Moving: '" + $nugetdllfile + "' -> '" + $assembliesfolder + "'") -f Green
            move $nugetdllfile $assembliesfolder
        }
        Write-Host ("Deleting folder: '" + $_.FullName + "'") -f Green
        rd -Recurse -Force $_.FullName
    }

    return $dllfile
}

Main
