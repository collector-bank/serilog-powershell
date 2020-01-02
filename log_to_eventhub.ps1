Set-StrictMode -v latest
$ErrorActionPreference = "Stop"

function Main($mainargs)
{
    if (!$mainargs -or $mainargs.Count -ne 1)
    {
        Write-Host ("Usage: pwsh log_to_eventhub.ps1 <eventhubconnstr>") -f Red
        exit 1
    }

    $connstr = $mainargs[0]

    $logger = Setup-Logging $connstr

    $logger.Information("hello123")
}

function Setup-Logging()
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

    Load-Dependencies

    Add-Type $csharpcode -ReferencedAssemblies "Serilog.dll","Serilog.Formatting.Compact.dll","System.Linq.dll","netstandard","System.Runtime.Extensions","System.Runtime","System.Collections","System.ObjectModel"

    $logger = ([Serilog.LoggerConfiguration]::new()).WriteTo.Sink([Serilog.Sinks.AzureEventHub.AzureEventHubSink]::new(([Microsoft.Azure.EventHubs.EventHubClient]::CreateFromConnectionString($connstr)),([ScalarValueTypeSuffixJsonFormatter]::new()))).CreateLogger()

    return $logger
}

function Load-Dependencies()
{
    [string[]] $nugets = `
        "Microsoft.Azure.Amqp",
        "Microsoft.Azure.EventHubs",
        "Microsoft.Azure.ServiceBus",
        "Microsoft.IdentityModel.Clients.ActiveDirectory",
        "Serilog",
        "Serilog.Formatting.Compact",
        "Serilog.Sinks.AzureEventHub",
        "Serilog.Sinks.PeriodicBatching"

    foreach ($nuget in $nugets)
    {
        Download-Nuget $nuget
    }
    foreach ($nuget in $nugets)
    {
        [string] $filename = Join-Path (pwd).Path ($nuget + ".dll")
        Write-Host ("Loading: '" + $filename + "'") -f Green
        Import-Module $filename
    }
}

function Download-Nuget([string] $packageName)
{
    [string] $dllfile = $packageName + ".dll"
    if (Test-Path $dllfile)
    {
        Write-Host ("File already downloaded: '" + $dllfile + "'") -f Green
        return
    }

    [string] $url = "https://www.nuget.org/packages/" + $packageName

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

    [string] $nugetfile = $packageName + ".nupkg"

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

    if (Test-Path $packageName)
    {
        Write-Host ("Deleting folder: '" + $packageName + "'") -f Green
        rd -Recurse -Force $packageName
    }

    Write-Host ("Extracting: '" + $nugetfile + "'") -f Green
    Expand-Archive $nugetfile

    if (Test-Path $nugetfile)
    {
        Write-Host ("Deleting file: '" + $nugetfile + "'") -f Green
        del $nugetfile
    }

    dir -Directory | % {
        dir (Join-Path $_.Name "lib" "netstandard*") | Sort-Object | Select-Object -Last 1 | dir -Filter *.dll | % {
            [string] $nugetdllfile = $_.FullName.Substring((pwd).Path.Length+1)
            Write-Host ("Moving: '" + $nugetdllfile + "' -> .") -f Green
            move $nugetdllfile .
        }
        Write-Host ("Deleting folder: '" + $_.FullName + "'") -f Green
        rd -Recurse -Force $_.FullName
    }
}

Main $args
