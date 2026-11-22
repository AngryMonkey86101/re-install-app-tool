#Requires -Version 5.1
<#
    Пакетный установщик программ с графическим интерфейсом.

    Список программ берётся из apps.json рядом со скриптом.
    Выбор пользователя (кнопка «Сохранить выбор») хранится в selection.json.
    Логи пишутся в папку logs\.
#>

$ErrorActionPreference = 'Stop'
$ScriptPath    = $PSCommandPath
$Root          = $PSScriptRoot
$ConfigPath    = Join-Path $Root 'apps.json'
$SelectionPath = Join-Path $Root 'selection.json'
$LogDir        = Join-Path $Root 'logs'

# ---------------------------------------------------------------------------
# Права администратора и STA-поток (нужен для WPF)
# ---------------------------------------------------------------------------
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin  = (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$isSta    = [Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA'
if (-not $isAdmin -or -not $isSta) {
    $argList = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$ScriptPath`""
    try {
        if ($isAdmin) { Start-Process powershell.exe -ArgumentList $argList }
        else          { Start-Process powershell.exe -ArgumentList $argList -Verb RunAs }
    } catch {
        Write-Host 'Для установки программ нужны права администратора.' -ForegroundColor Red
        Start-Sleep -Seconds 3
    }
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

trap {
    [System.Windows.MessageBox]::Show("Непредвиденная ошибка:`n`n$($_.Exception.Message)", 'Пакетная установка', 'OK', 'Error') | Out-Null
    exit 1
}

# ---------------------------------------------------------------------------
# Модель элемента списка (с уведомлением UI об изменениях)
# ---------------------------------------------------------------------------
if (-not ('BatchInstaller.AppItem' -as [type])) {
    Add-Type -TypeDefinition @'
using System.ComponentModel;
namespace BatchInstaller {
    public class AppItem : INotifyPropertyChanged {
        private bool _isSelected;
        private string _status = "";
        public event PropertyChangedEventHandler PropertyChanged;
        private void Notify(string name) {
            PropertyChangedEventHandler h = PropertyChanged;
            if (h != null) h(this, new PropertyChangedEventArgs(name));
        }
        public bool IsSelected {
            get { return _isSelected; }
            set { if (_isSelected != value) { _isSelected = value; Notify("IsSelected"); } }
        }
        public string Status {
            get { return _status; }
            set { _status = value ?? ""; Notify("Status"); Notify("StatusColor"); }
        }
        public string StatusColor {
            get {
                if (_status.StartsWith("Ошибка") || _status.StartsWith("Не найдено")) return "#C62828";
                if (_status.StartsWith("Установка") || _status.StartsWith("Загрузка")) return "#1565C0";
                if (_status.StartsWith("Отменено")) return "#B26A00";
                if (_status.StartsWith("В очереди")) return "#6B7280";
                return "#2E7D32";
            }
        }
        public int Index { get; set; }
        public string Name { get; set; }
        public string Category { get; set; }
        public string Description { get; set; }
        public string Source { get; set; }
        public string SourceLabel { get; set; }
        public string Id { get; set; }
        public string WingetSource { get; set; }
        public string Url { get; set; }
        public string UrlPage { get; set; }
        public string UrlPattern { get; set; }
        public string Path { get; set; }
        public string FileName { get; set; }
        public string SilentArgs { get; set; }
        public string NormalArgs { get; set; }
        public string ExtraArgs { get; set; }
        public bool DefaultChecked { get; set; }
        public string Key { get { return string.IsNullOrEmpty(Id) ? Name : Id; } }
    }
}
'@
}

# ---------------------------------------------------------------------------
# Поиск winget
# ---------------------------------------------------------------------------
# Возвращает путь к winget, только если он реально запускается.
# Если файл есть, но не отвечает, вернётся $null и запустится починка/установка.
function Find-Winget {
    $cands = @()
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { $cands += $cmd.Source }
    $cands += @(Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | ForEach-Object { $_.FullName })
    $portable = Join-Path $env:ProgramData 'BatchInstaller\winget\winget.exe'
    if (Test-Path -LiteralPath $portable) { $cands += $portable }
    foreach ($c in $cands) {
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $c; $psi.Arguments = '--version'
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $p = [System.Diagnostics.Process]::Start($psi)
            $out = $p.StandardOutput.ReadToEndAsync()
            if ($p.WaitForExit(15000) -and $p.ExitCode -eq 0 -and $out.Result -match '\d+\.\d+') { return $c }
            if (-not $p.HasExited) { try { $p.Kill() } catch { } }
        } catch { }
    }
    return $null
}

$Winget = Find-Winget
# Если winget нет, он ставится автоматически после открытия окна (см. $WingetSetupWorker)

# ---------------------------------------------------------------------------
# Загрузка списка программ
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Не найден файл списка программ: $ConfigPath" }
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

$Items = New-Object 'System.Collections.ObjectModel.ObservableCollection[BatchInstaller.AppItem]'
$i = 0
foreach ($a in $config.apps) {
    $item = New-Object BatchInstaller.AppItem
    $item.Index          = $i
    $item.Name           = [string]$a.name
    $item.Category       = $(if ($a.category) { [string]$a.category } else { 'Прочее' })
    $item.Description    = [string]$a.description
    $item.Source         = $(if ($a.source) { ([string]$a.source).ToLower() } else { 'winget' })
    $item.Id             = [string]$a.id
    $item.WingetSource   = $(if ($a.wingetSource) { [string]$a.wingetSource } else { 'winget' })
    $item.Url            = [string]$a.url
    $item.UrlPage        = [string]$a.urlPage
    $item.UrlPattern     = [string]$a.urlPattern
    $item.Path           = [string]$a.path
    $item.FileName       = [string]$a.fileName
    $item.SilentArgs     = [string]$a.silentArgs
    $item.NormalArgs     = [string]$a.normalArgs
    $item.ExtraArgs      = [string]$a.extraArgs
    $item.DefaultChecked = [bool]$a.checked
    $item.IsSelected     = $item.DefaultChecked
    $item.SourceLabel    = switch ($item.Source) { 'winget' { 'winget' } 'url' { 'Загрузка' } 'local' { 'Локальный файл' } default { $item.Source } }
    $Items.Add($item)
    $i++
}

# Сохранённый выбор пользователя
if (Test-Path -LiteralPath $SelectionPath) {
    try {
        $saved = @(Get-Content -LiteralPath $SelectionPath -Raw -Encoding UTF8 | ConvertFrom-Json)
        foreach ($it in $Items) { $it.IsSelected = $saved -contains $it.Key }
    } catch { }
}

# ---------------------------------------------------------------------------
# Интерфейс
# ---------------------------------------------------------------------------
[xml]$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Пакетная установка программ" Height="800" Width="1200" MinHeight="600" MinWidth="980"
        WindowStartupLocation="CenterScreen" WindowStyle="None" ResizeMode="CanResize"
        FontFamily="Segoe UI" FontSize="13" Foreground="#16191C"
        TextOptions.TextFormattingMode="Display">
    <WindowChrome.WindowChrome>
        <WindowChrome CaptionHeight="56" ResizeBorderThickness="6" GlassFrameThickness="0" CornerRadius="0" UseAeroCaptionButtons="False"/>
    </WindowChrome.WindowChrome>

    <Window.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
            <GradientStop Color="#C4C7CB" Offset="0"/>
            <GradientStop Color="#CDD0D3" Offset="0.42"/>
            <GradientStop Color="#B9BEC3" Offset="0.58"/>
            <GradientStop Color="#A2AAB2" Offset="1"/>
        </LinearGradientBrush>
    </Window.Background>

    <Window.Resources>
        <SolidColorBrush x:Key="Ink" Color="#16191C"/>
        <SolidColorBrush x:Key="Muted" Color="#646A71"/>
        <SolidColorBrush x:Key="Hair" Color="#2B2F33"/>

        <!-- Мелкая серая подпись раздела -->
        <Style x:Key="Label" TargetType="TextBlock">
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="Foreground" Value="{StaticResource Muted}"/>
            <Setter Property="Margin" Value="0,0,0,12"/>
        </Style>

        <!-- Тонкая полоса прокрутки -->
        <Style TargetType="ScrollBar">
            <Setter Property="Width" Value="8"/>
            <Setter Property="MinWidth" Value="8"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ScrollBar">
                        <Track x:Name="PART_Track" IsDirectionReversed="True">
                            <Track.Thumb>
                                <Thumb>
                                    <Thumb.Template>
                                        <ControlTemplate TargetType="Thumb">
                                            <Border Background="Transparent">
                                                <Border Width="2" Background="#4A5056" HorizontalAlignment="Center"/>
                                            </Border>
                                        </ControlTemplate>
                                    </Thumb.Template>
                                </Thumb>
                            </Track.Thumb>
                        </Track>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Кнопки окна (свернуть / закрыть) -->
        <Style x:Key="ChromeButton" TargetType="Button">
            <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Width" Value="30"/>
            <Setter Property="Height" Value="30"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="Transparent">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#26FFFFFF"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Квадратная плитка с иконкой (как Spot / Area / Target / Sun) -->
        <ControlTemplate x:Key="TileTemplate" TargetType="Button">
            <Border x:Name="Bd" Background="Transparent" BorderBrush="{StaticResource Hair}" BorderThickness="1" Padding="8,6">
                <ContentPresenter x:Name="Cp" TextElement.Foreground="{StaticResource Ink}"/>
            </Border>
            <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter TargetName="Bd" Property="Background" Value="#2EFFFFFF"/>
                </Trigger>
                <Trigger Property="IsPressed" Value="True">
                    <Setter TargetName="Bd" Property="Background" Value="#16191C"/>
                    <Setter TargetName="Cp" Property="TextElement.Foreground" Value="White"/>
                </Trigger>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter TargetName="Bd" Property="Opacity" Value="0.4"/>
                </Trigger>
            </ControlTemplate.Triggers>
        </ControlTemplate>
        <ControlTemplate x:Key="ToggleTileTemplate" TargetType="RadioButton">
            <Border x:Name="Bd" Background="Transparent" BorderBrush="{StaticResource Hair}" BorderThickness="1" Padding="8,6">
                <ContentPresenter x:Name="Cp" TextElement.Foreground="{StaticResource Ink}"/>
            </Border>
            <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter TargetName="Bd" Property="Background" Value="#2EFFFFFF"/>
                </Trigger>
                <Trigger Property="IsChecked" Value="True">
                    <Setter TargetName="Bd" Property="Background" Value="#16191C"/>
                    <Setter TargetName="Bd" Property="BorderBrush" Value="#16191C"/>
                    <Setter TargetName="Cp" Property="TextElement.Foreground" Value="White"/>
                </Trigger>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter TargetName="Bd" Property="Opacity" Value="0.4"/>
                </Trigger>
            </ControlTemplate.Triggers>
        </ControlTemplate>
        <Style x:Key="Tile" TargetType="Button">
            <Setter Property="Template" Value="{StaticResource TileTemplate}"/>
            <Setter Property="Height" Value="58"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="VerticalContentAlignment" Value="Stretch"/>
        </Style>
        <Style x:Key="TileRadio" TargetType="RadioButton">
            <Setter Property="Template" Value="{StaticResource ToggleTileTemplate}"/>
            <Setter Property="Height" Value="58"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="GroupName" Value="Mode"/>
        </Style>
        <!-- Иконка плитки берёт цвет текста -->
        <Style x:Key="Glyph" TargetType="Path">
            <Setter Property="Stroke" Value="{Binding Path=(TextElement.Foreground), RelativeSource={RelativeSource Self}}"/>
            <Setter Property="StrokeThickness" Value="1"/>
            <Setter Property="HorizontalAlignment" Value="Right"/>
            <Setter Property="VerticalAlignment" Value="Top"/>
            <Setter Property="Margin" Value="0,2,0,0"/>
        </Style>
        <Style x:Key="TileText" TargetType="TextBlock">
            <Setter Property="FontSize" Value="11.5"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="VerticalAlignment" Value="Bottom"/>
            <Setter Property="TextWrapping" Value="Wrap"/>
        </Style>

        <!-- Чёрная полоса (как выбранный пункт Rotation) -->
        <Style x:Key="BarButton" TargetType="Button">
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Height" Value="40"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="#16191C" Padding="14,0">
                            <DockPanel>
                                <Path DockPanel.Dock="Right" Data="M0,5 H14 M10,1 L14,5 L10,9" Stroke="White" StrokeThickness="1.2" VerticalAlignment="Center"/>
                                <TextBlock Text="{TemplateBinding Content}" Foreground="White" FontWeight="SemiBold" FontSize="13.5" VerticalAlignment="Center"/>
                            </DockPanel>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#2C3136"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="Bd" Property="Opacity" Value="0.35"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="OutlineButton" TargetType="Button">
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Height" Value="40"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="Transparent" BorderBrush="{StaticResource Hair}" BorderThickness="1" Padding="14,0">
                            <TextBlock Text="{TemplateBinding Content}" FontSize="12.5" VerticalAlignment="Center" HorizontalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#2EFFFFFF"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="Bd" Property="Opacity" Value="0.35"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Текстовая ссылка -->
        <Style x:Key="LinkButton" TargetType="Button">
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Foreground" Value="{StaticResource Ink}"/>
            <Setter Property="FontSize" Value="11.5"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <TextBlock x:Name="T" Text="{TemplateBinding Content}" TextDecorations="Underline" VerticalAlignment="Center" Background="Transparent"/>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="T" Property="Foreground" Value="#000000"/>
                                <Setter TargetName="T" Property="FontWeight" Value="SemiBold"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="T" Property="Opacity" Value="0.4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Поле поиска: только нижняя линия -->
        <Style x:Key="LineBox" TargetType="TextBox">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="{StaticResource Ink}"/>
            <Setter Property="CaretBrush" Value="{StaticResource Ink}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border x:Name="Bd" BorderBrush="#5A6067" BorderThickness="0,0,0,1" Background="Transparent" Padding="0,4">
                            <ScrollViewer x:Name="PART_ContentHost" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="Bd" Property="BorderBrush" Value="#16191C"/>
                                <Setter TargetName="Bd" Property="BorderThickness" Value="0,0,0,2"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Прогресс: тонкая линия с чёрным бегунком (как Brightness) -->
        <Style TargetType="ProgressBar">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ProgressBar">
                        <Grid Height="8">
                            <Border x:Name="PART_Track" Height="1" VerticalAlignment="Center" Background="#4A5056"/>
                            <Border x:Name="PART_Indicator" Height="3" VerticalAlignment="Center" HorizontalAlignment="Left" Background="#16191C"/>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Пункты навигации по категориям (как Render / Rotation / Texture) -->
        <Style x:Key="NavItem" TargetType="ListBoxItem">
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ListBoxItem">
                        <Border x:Name="Bd" Background="Transparent" Height="36" Padding="12,0">
                            <ContentPresenter x:Name="Cp" VerticalAlignment="Center" TextElement.Foreground="{StaticResource Ink}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#26FFFFFF"/>
                            </Trigger>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#16191C"/>
                                <Setter TargetName="Cp" Property="TextElement.Foreground" Value="White"/>
                                <Setter TargetName="Cp" Property="TextElement.FontWeight" Value="SemiBold"/>
                                <Setter TargetName="Cp" Property="TextElement.FontSize" Value="13.5"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Строка программы: вся строка — это флажок -->
        <Style x:Key="RowCheck" TargetType="CheckBox">
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <Border x:Name="Bd" Background="Transparent" Padding="10,8" BorderBrush="#2E000000" BorderThickness="0,0,0,1">
                            <DockPanel>
                                <Border x:Name="Box" DockPanel.Dock="Left" Width="15" Height="15" BorderBrush="{StaticResource Hair}" BorderThickness="1.2"
                                        VerticalAlignment="Center" Margin="0,0,16,0" Background="Transparent">
                                    <Path x:Name="Mark" Data="M2.5,6.5 L5.3,9.3 L10.5,3.2" Stroke="White" StrokeThickness="1.6" Visibility="Collapsed"/>
                                </Border>
                                <ContentPresenter VerticalAlignment="Center"/>
                            </DockPanel>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#24FFFFFF"/>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="Box" Property="Background" Value="#16191C"/>
                                <Setter TargetName="Box" Property="BorderBrush" Value="#16191C"/>
                                <Setter TargetName="Mark" Property="Visibility" Value="Visible"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="PlainItem" TargetType="ListBoxItem">
            <Setter Property="Focusable" Value="False"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ListBoxItem">
                        <ContentPresenter/>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid x:Name="Root">
        <!-- Сетка «пола» в нижней части, как на референсе -->
        <Rectangle VerticalAlignment="Bottom" Height="430" IsHitTestVisible="False" Opacity="0.55">
            <Rectangle.Fill>
                <DrawingBrush TileMode="Tile" Viewport="0,0,96,96" ViewportUnits="Absolute" Stretch="None">
                    <DrawingBrush.Drawing>
                        <GeometryDrawing Geometry="M0,0 L96,0 M0,0 L0,96">
                            <GeometryDrawing.Pen>
                                <Pen Brush="#8E969E" Thickness="1"/>
                            </GeometryDrawing.Pen>
                        </GeometryDrawing>
                    </DrawingBrush.Drawing>
                </DrawingBrush>
            </Rectangle.Fill>
            <Rectangle.OpacityMask>
                <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                    <GradientStop Color="#00000000" Offset="0"/>
                    <GradientStop Color="#FF000000" Offset="1"/>
                </LinearGradientBrush>
            </Rectangle.OpacityMask>
        </Rectangle>

        <Grid Margin="40,22,40,26">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <!-- Верхняя строка: день — дата ... год, кнопки окна -->
            <DockPanel Grid.Row="0" Height="34">
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock x:Name="HeaderYear" FontSize="15" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,24,0"/>
                    <Button x:Name="BtnMin" Style="{StaticResource ChromeButton}" ToolTip="Свернуть">
                        <Path Data="M0,0.5 H13" Stroke="{StaticResource Ink}" StrokeThickness="1"/>
                    </Button>
                    <Button x:Name="BtnClose" Style="{StaticResource ChromeButton}" ToolTip="Закрыть">
                        <Path Data="M0,0 L12,12 M12,0 L0,12" Stroke="{StaticResource Ink}" StrokeThickness="1"/>
                    </Button>
                </StackPanel>
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock x:Name="HeaderDay" FontSize="15" VerticalAlignment="Center"/>
                    <Rectangle Width="26" Height="1" Fill="{StaticResource Ink}" Margin="22,0" VerticalAlignment="Center"/>
                    <TextBlock x:Name="HeaderDate" FontSize="15" VerticalAlignment="Center"/>
                </StackPanel>
            </DockPanel>

            <!-- Основная часть: три колонки -->
            <Grid Grid.Row="1" Margin="0,36,0,18">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="230"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="250"/>
                </Grid.ColumnDefinitions>

                <!-- Левая колонка: поиск и категории -->
                <DockPanel Grid.Column="0" Margin="0,0,0,0">
                    <StackPanel DockPanel.Dock="Top">
                        <TextBlock Text="Поиск" Style="{StaticResource Label}"/>
                        <Grid Margin="0,0,0,34">
                            <TextBox x:Name="SearchBox" Style="{StaticResource LineBox}" Padding="22,0,0,0"/>
                            <Path Data="M5,0.5 A4.5,4.5 0 1 1 4.99,0.5 M8.3,8.3 L12,12" Stroke="#4A5056" StrokeThickness="1.2"
                                  VerticalAlignment="Center" HorizontalAlignment="Left" IsHitTestVisible="False"/>
                            <TextBlock x:Name="SearchHint" Text="Название программы" Foreground="#6E747B" Margin="22,0,0,0"
                                       VerticalAlignment="Center" IsHitTestVisible="False"/>
                        </Grid>
                        <TextBlock Text="Категории" Style="{StaticResource Label}"/>
                    </StackPanel>
                    <ListBox x:Name="CatList" Background="Transparent" BorderThickness="0" Padding="0"
                             ItemContainerStyle="{StaticResource NavItem}"
                             ScrollViewer.HorizontalScrollBarVisibility="Disabled">
                        <ListBox.ItemTemplate>
                            <DataTemplate>
                                <DockPanel>
                                    <TextBlock DockPanel.Dock="Right" Text="{Binding Count}" FontSize="11" Opacity="0.6" VerticalAlignment="Center"/>
                                    <Path Data="M7,0.5 L13,3.8 L13,10.2 L7,13.5 L1,10.2 L1,3.8 Z M1,3.8 L7,7 L13,3.8 M7,7 L7,13.5"
                                          Stroke="{Binding Path=(TextElement.Foreground), RelativeSource={RelativeSource Self}}" StrokeThickness="1.1"
                                          VerticalAlignment="Center" Margin="0,0,14,0"/>
                                    <TextBlock Text="{Binding Name}" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                                </DockPanel>
                            </DataTemplate>
                        </ListBox.ItemTemplate>
                    </ListBox>
                </DockPanel>

                <!-- Центр: список программ и счётчик -->
                <DockPanel Grid.Column="1" Margin="48,0,48,0">
                    <DockPanel DockPanel.Dock="Top" Margin="0,0,0,4">
                        <TextBlock x:Name="WingetInfo" DockPanel.Dock="Right" FontSize="11" Foreground="{StaticResource Muted}"/>
                        <TextBlock Text="Программы" Style="{StaticResource Label}" Margin="0"/>
                    </DockPanel>
                    <StackPanel DockPanel.Dock="Bottom" HorizontalAlignment="Center" Margin="0,16,0,0">
                        <Rectangle Width="56" Height="3" Fill="{StaticResource Ink}" Margin="0,0,0,12"/>
                        <TextBlock Text="Выбрано" FontSize="11" Foreground="{StaticResource Muted}" HorizontalAlignment="Center"/>
                        <TextBlock x:Name="CountText" FontSize="30" FontWeight="Light" HorizontalAlignment="Center"/>
                    </StackPanel>
                    <Border BorderBrush="{StaticResource Hair}" BorderThickness="0,1,0,1">
                        <ListBox x:Name="AppGrid" Background="Transparent" BorderThickness="0" Padding="0"
                                 ItemContainerStyle="{StaticResource PlainItem}"
                                 ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                                 VirtualizingPanel.IsVirtualizingWhenGrouping="True">
                            <ListBox.ItemTemplate>
                                <DataTemplate>
                                    <CheckBox Style="{StaticResource RowCheck}" IsChecked="{Binding IsSelected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}">
                                        <Grid>
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="86"/>
                                                <ColumnDefinition Width="150"/>
                                            </Grid.ColumnDefinitions>
                                            <StackPanel Grid.Column="0" Margin="0,0,12,0">
                                                <TextBlock Text="{Binding Name}" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                                                <TextBlock Text="{Binding Description}" FontSize="11.5" Foreground="#555B62" TextTrimming="CharacterEllipsis" Margin="0,1,0,0"/>
                                            </StackPanel>
                                            <TextBlock Grid.Column="1" Text="{Binding SourceLabel}" FontSize="11" Foreground="#646A71" VerticalAlignment="Center"/>
                                            <TextBlock Grid.Column="2" Text="{Binding Status}" Foreground="{Binding StatusColor}" FontSize="11.5"
                                                       VerticalAlignment="Center" HorizontalAlignment="Right" TextTrimming="CharacterEllipsis"/>
                                        </Grid>
                                    </CheckBox>
                                </DataTemplate>
                            </ListBox.ItemTemplate>
                            <ListBox.GroupStyle>
                                <GroupStyle>
                                    <GroupStyle.HeaderTemplate>
                                        <DataTemplate>
                                            <DockPanel Margin="10,16,10,6">
                                                <Button DockPanel.Dock="Right" Style="{StaticResource LinkButton}" Content="выбрать / снять" Tag="{Binding Name}"/>
                                                <StackPanel Orientation="Horizontal">
                                                    <TextBlock Text="{Binding Name}" FontSize="11" Foreground="#4A5056"/>
                                                    <TextBlock Text="{Binding ItemCount, StringFormat='  {0}'}" FontSize="11" Foreground="#7A8087"/>
                                                </StackPanel>
                                            </DockPanel>
                                        </DataTemplate>
                                    </GroupStyle.HeaderTemplate>
                                </GroupStyle>
                            </ListBox.GroupStyle>
                        </ListBox>
                    </Border>
                </DockPanel>

                <!-- Правая колонка: режим, выбор, прогресс, журнал, запуск -->
                <DockPanel Grid.Column="2">
                    <StackPanel DockPanel.Dock="Top">
                        <TextBlock Text="Режим установки" Style="{StaticResource Label}"/>
                        <UniformGrid Columns="2" Margin="0,0,0,0">
                            <RadioButton x:Name="ChkSilent" Style="{StaticResource TileRadio}" IsChecked="True" Margin="0,0,5,0"
                                         ToolTip="Без окон установщиков и вопросов">
                                <Grid>
                                    <Ellipse Width="9" Height="9" Fill="{Binding Path=(TextElement.Foreground), RelativeSource={RelativeSource Self}}"
                                             HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,2,0,0"/>
                                    <TextBlock Text="Тихая" Style="{StaticResource TileText}"/>
                                </Grid>
                            </RadioButton>
                            <RadioButton x:Name="RbWizard" Style="{StaticResource TileRadio}" Margin="5,0,0,0"
                                         ToolTip="У каждой программы откроется её обычный мастер установки">
                                <Grid>
                                    <Path Style="{StaticResource Glyph}" Data="M0.5,0.5 H12.5 V10.5 H0.5 Z M0.5,3 H12.5"/>
                                    <TextBlock Text="С мастером" Style="{StaticResource TileText}"/>
                                </Grid>
                            </RadioButton>
                        </UniformGrid>

                        <TextBlock Text="Выбор" Style="{StaticResource Label}" Margin="0,24,0,12"/>
                        <UniformGrid Columns="2">
                            <Button x:Name="BtnAll" Style="{StaticResource Tile}" Margin="0,0,5,10" ToolTip="Отметить все видимые программы">
                                <Grid>
                                    <Path Style="{StaticResource Glyph}" StrokeThickness="0"
                                          Fill="{Binding Path=(TextElement.Foreground), RelativeSource={RelativeSource Self}}"
                                          Data="M0,0h2v2h-2z M4,0h2v2h-2z M8,0h2v2h-2z M0,4h2v2h-2z M4,4h2v2h-2z M8,4h2v2h-2z M0,8h2v2h-2z M4,8h2v2h-2z M8,8h2v2h-2z"/>
                                    <TextBlock Text="Все" Style="{StaticResource TileText}"/>
                                </Grid>
                            </Button>
                            <Button x:Name="BtnNone" Style="{StaticResource Tile}" Margin="5,0,0,10" ToolTip="Снять отметки с видимых программ">
                                <Grid>
                                    <Path Style="{StaticResource Glyph}" Data="M5.5,0.5 A5,5 0 1 1 5.49,0.5"/>
                                    <TextBlock Text="Ничего" Style="{StaticResource TileText}"/>
                                </Grid>
                            </Button>
                            <Button x:Name="BtnDefault" Style="{StaticResource Tile}" Margin="0,0,5,0" ToolTip="Вернуть отметки из apps.json">
                                <Grid>
                                    <Path Style="{StaticResource Glyph}" Data="M10.5,0.5 L1.5,9.5 M1.5,4 V9.5 H7"/>
                                    <TextBlock Text="По умолчанию" Style="{StaticResource TileText}"/>
                                </Grid>
                            </Button>
                            <Button x:Name="BtnCheck" Style="{StaticResource Tile}" Margin="5,0,0,0" ToolTip="Найти уже установленные программы и снять с них отметку">
                                <Grid>
                                    <Path Style="{StaticResource Glyph}" Data="M4.5,0.5 A4,4 0 1 1 4.49,0.5 M7.5,7.5 L11,11"/>
                                    <TextBlock Text="Установленные" Style="{StaticResource TileText}"/>
                                </Grid>
                            </Button>
                        </UniformGrid>
                        <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                            <Button x:Name="BtnSave" Style="{StaticResource LinkButton}" Content="Сохранить выбор" Margin="0,0,16,0"/>
                            <Button x:Name="BtnEdit" Style="{StaticResource LinkButton}" Content="Изменить список"/>
                        </StackPanel>

                        <TextBlock Text="Прогресс" Style="{StaticResource Label}" Margin="0,24,0,8"/>
                        <ProgressBar x:Name="Progress" Minimum="0" Maximum="1" Value="0"/>
                        <TextBlock x:Name="ProgressText" Text="Готово к установке" FontSize="11.5" Margin="0,6,0,0" TextWrapping="Wrap"/>
                    </StackPanel>

                    <StackPanel DockPanel.Dock="Bottom" Margin="0,14,0,0">
                        <Button x:Name="BtnInstall" Style="{StaticResource BarButton}" Content="Установить выбранные"/>
                        <Button x:Name="BtnCancel" Style="{StaticResource OutlineButton}" Content="Отмена" IsEnabled="False" Margin="0,8,0,0" Height="32"/>
                    </StackPanel>

                    <DockPanel Margin="0,22,0,0">
                        <TextBlock DockPanel.Dock="Top" Text="Журнал" Style="{StaticResource Label}" Margin="0,0,0,8"/>
                        <TextBox x:Name="LogBox" IsReadOnly="True" FontFamily="Consolas" FontSize="11"
                                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" TextWrapping="Wrap"
                                 Background="#1AFFFFFF" Foreground="#2B2F33" BorderBrush="#5A6067" BorderThickness="0,1,0,1" Padding="0,6"/>
                    </DockPanel>
                </DockPanel>
            </Grid>

            <!-- Нижняя строка: знак слева, номер справа -->
            <DockPanel Grid.Row="2">
                <TextBlock x:Name="PageNum" DockPanel.Dock="Right" FontSize="15" FontWeight="SemiBold" VerticalAlignment="Bottom"
                           ToolTip="Сколько программ выбрано"/>
                <Border BorderBrush="{StaticResource Ink}" BorderThickness="1.2" Width="44" Height="48" HorizontalAlignment="Left" Padding="7,5">
                    <Grid>
                        <TextBlock Text="APP&#10;SET&#10;UP" FontSize="9.5" FontWeight="Bold" LineHeight="11" LineStackingStrategy="BlockLineHeight"/>
                        <Rectangle Width="3" Height="3" Fill="{StaticResource Ink}" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,1,2"/>
                    </Grid>
                </Border>
            </DockPanel>
        </Grid>
    </Grid>
</Window>
'@

$Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $Xaml))
$ui = @{}
$Xaml.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object {
    $name = $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
    if ($name) { $ui[$name] = $Window.FindName($name) }
}

# Представление с группировкой по категориям и фильтром поиска
$View = [System.Windows.Data.CollectionViewSource]::GetDefaultView($Items)
$View.GroupDescriptions.Add((New-Object System.Windows.Data.PropertyGroupDescription 'Category'))
$ui.AppGrid.ItemsSource = $View

# Категории для левой панели (в порядке появления в apps.json)
$script:CatFilter = $null
$Cats = New-Object System.Collections.ArrayList
[void]$Cats.Add([pscustomobject]@{ Name = 'Все программы'; Key = $null; Count = $Items.Count })
foreach ($g in ($Items | Group-Object Category)) {
    [void]$Cats.Add([pscustomobject]@{ Name = $g.Name; Key = $g.Name; Count = $g.Count })
}
$ui.CatList.ItemsSource = $Cats
$ui.CatList.SelectedIndex = 0

# ---------------------------------------------------------------------------
# Фоновая работа: очередь сообщений от рабочих потоков к UI
# ---------------------------------------------------------------------------
$Sync = [hashtable]::Synchronized(@{
    Queue   = New-Object 'System.Collections.Concurrent.ConcurrentQueue[hashtable]'
    Cancel  = $false
    Workers = New-Object System.Collections.ArrayList
})
$script:Busy = $false

function Start-Worker([scriptblock]$Code, [object[]]$Arguments) {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($Code.ToString())
    foreach ($arg in $Arguments) { [void]$ps.AddArgument($arg) }
    [void]$Sync.Workers.Add(@{ PS = $ps; Handle = $ps.BeginInvoke(); RS = $rs })
}

function Clear-Workers {
    foreach ($w in @($Sync.Workers)) {
        if ($w.Handle.IsCompleted) {
            try { $w.PS.EndInvoke($w.Handle) | Out-Null } catch { }
            $w.PS.Dispose(); $w.RS.Dispose()
            $Sync.Workers.Remove($w)
        }
    }
}

# Установка выбранных программ (выполняется в отдельном потоке)
$InstallWorker = {
    param($sync, $jobs, [bool]$silent, $winget, $root, $logFile)

    function Send([hashtable]$m) { $sync.Queue.Enqueue($m) }
    function Log([string]$t) {
        $line = '[{0:HH:mm:ss}] {1}' -f (Get-Date), $t
        Send @{ Type = 'log'; Text = $line }
        try { Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8 } catch { }
    }

    # Запуск консольной программы (winget) с выводом в лог
    function Invoke-Captured([string]$file, [string]$arguments) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName  = $file
        $psi.Arguments = $arguments
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
        $p = [System.Diagnostics.Process]::Start($psi)
        $errTask = $p.StandardError.ReadToEndAsync()
        $last = ''
        while ($null -ne ($line = $p.StandardOutput.ReadLine())) {
            $t = $line.Trim()
            if ($t.Length -le 1) { continue }                 # спиннер
            if ($t -match '[▀-▟]') { continue }     # полоса прогресса
            if ($t -eq $last) { continue }
            $last = $t
            Log "    $t"
        }
        $p.WaitForExit()
        $err = $errTask.Result
        if ($err) { $err -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { Log "    $_" } }
        return $p.ExitCode
    }

    # Запуск обычного установщика (.exe / .msi)
    function Invoke-Installer([string]$file, [string]$arguments) {
        if ($file -match '\.msi$') {
            $arguments = "/i `"$file`" $arguments"
            $file = Join-Path $env:SystemRoot 'System32\msiexec.exe'
        }
        $sp = @{ FilePath = $file; PassThru = $true }
        if ($arguments.Trim()) { $sp.ArgumentList = $arguments }
        $p = Start-Process @sp
        $null = $p.Handle    # без этого ExitCode иногда пустой
        $p.WaitForExit()
        return $p.ExitCode
    }

    # --- Ярлыки на рабочем столе ---
    $startDirs = @((Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
                   (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'))
    $publicDesktop = Join-Path $env:PUBLIC 'Desktop'
    $deskDirs = @($publicDesktop, [Environment]::GetFolderPath('Desktop'))
    $junk = '(?i)uninstall|unins|удал|деинстал|readme|help|справк|website|web site|сайт|manual|руководств|license|лиценз|changelog|release notes'

    function Get-Links([string[]]$dirs) {
        $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($d in $dirs) {
            if (Test-Path -LiteralPath $d) {
                Get-ChildItem -LiteralPath $d -Recurse -Include *.lnk, *.url -File -ErrorAction SilentlyContinue | ForEach-Object { [void]$set.Add($_.FullName) }
            }
        }
        return ,$set
    }
    function Test-OnDesktop([string]$name) {
        foreach ($d in $deskDirs) { if (Test-Path -LiteralPath (Join-Path $d $name)) { return $true } }
        return $false
    }
    function New-Link([string]$target, [string]$name) {
        $lnk = Join-Path $publicDesktop "$name.lnk"
        $sh = New-Object -ComObject WScript.Shell
        $sc = $sh.CreateShortcut($lnk)
        $sc.TargetPath = $target
        $sc.WorkingDirectory = Split-Path -Parent $target
        $sc.Save()
        return $lnk
    }
    # Главный exe программы, если установщик не создал ярлык в «Пуске»
    function Find-AppExe([string]$appName) {
        $word = ($appName -split '[\s\-\.]+' | Where-Object { $_.Length -ge 3 } | Select-Object -First 1)
        if (-not $word) { return $null }
        $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs')) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
        foreach ($r in $roots) {
            foreach ($dir in @(Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$word*" })) {
                $exe = Get-ChildItem -LiteralPath $dir.FullName -Filter *.exe -File -ErrorAction SilentlyContinue |
                       Where-Object { $_.Name -like "*$word*" -and $_.Name -notmatch $junk } | Select-Object -First 1
                if ($exe) { return $exe.FullName }
            }
        }
        return $null
    }
    function Add-DesktopShortcut($j, $startBefore, $deskBefore) {
        if (-not $j.Shortcut) { return }
        try {
            $deskNew = @((Get-Links $deskDirs) | Where-Object { -not $deskBefore.Contains($_) })
            if ($deskNew.Count) { Log "    Ярлык на рабочем столе: $([IO.Path]::GetFileName($deskNew[0]))"; return }
            $startNew = @((Get-Links $startDirs) | Where-Object { -not $startBefore.Contains($_) -and [IO.Path]::GetFileName($_) -notmatch $junk })
            foreach ($l in $startNew) { Log "    В меню «Пуск»: $($l.Substring($l.IndexOf('Programs') + 9))" }
            if ($startNew.Count) {
                # Из новых ярлыков «Пуска» берём похожий на название программы, иначе первый
                $word = ($j.Name -split '[\s\-\.]+' | Select-Object -First 1)
                $pick = @($startNew | Where-Object { [IO.Path]::GetFileNameWithoutExtension($_) -like "*$word*" })
                if (-not $pick.Count) { $pick = @($startNew[0]) }
                foreach ($l in ($pick | Select-Object -First 2)) {
                    $n = [IO.Path]::GetFileName($l)
                    if (Test-OnDesktop $n) { continue }
                    Copy-Item -LiteralPath $l -Destination (Join-Path $publicDesktop $n) -Force
                    Log "    Создан ярлык на рабочем столе: $n"
                }
                return
            }
            $exe = $null
            if ($j.Exe) { $exe = [Environment]::ExpandEnvironmentVariables($j.Exe); if (-not (Test-Path -LiteralPath $exe)) { Log "    Не найден exe из apps.json: $exe"; $exe = $null } }
            if (-not $exe) { foreach ($e in (Find-ArpEntry $j)) { $exe = Get-ArpExe $e; if ($exe) { break } } }
            if (-not $exe) { $exe = Find-AppExe $j.Name }
            if ($exe) {
                if (Test-OnDesktop "$($j.Name).lnk") { return }
                $lnk = New-Link $exe $j.Name
                Log "    Установщик не создал ярлык. Создан ярлык на рабочем столе: $([IO.Path]::GetFileName($lnk)) -> $exe"
            } else {
                Log '    Ярлык не найден и exe программы не обнаружен. Можно указать путь к exe в apps.json (поле "exe").'
            }
        } catch { Log "    Не удалось создать ярлык: $($_.Exception.Message)" }
    }

    # --- Проверка, что программа действительно установилась (раздел «Программы и компоненты») ---
    function Get-ArpEntries {
        $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        foreach ($k in $keys) {
            Get-ItemProperty -Path $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName } | ForEach-Object {
                [pscustomobject]@{ Key = [string]$_.PSPath; Name = [string]$_.DisplayName; Location = [string]$_.InstallLocation; Icon = [string]$_.DisplayIcon }
            }
        }
    }
    # Слова для поиска программы: из названия и из id winget (AmneziaVPN.AmneziaVPN -> AmneziaVPN)
    function Get-AppWords($j) {
        $w = @(($j.Name -split '[\s\-\.]+') | Where-Object { $_.Length -ge 3 } | Select-Object -First 1)
        if ($j.Id) { $w += @(($j.Id -split '\.') | Select-Object -Last 1) }
        return @($w | Where-Object { $_ } | Select-Object -Unique)
    }
    function Find-ArpEntry($j) {
        $words = Get-AppWords $j
        @(Get-ArpEntries | Where-Object { $n = $_.Name; @($words | Where-Object { $n -like "*$_*" }).Count -gt 0 })
    }
    # exe программы из записи в реестре (DisplayIcon или папка установки)
    function Get-ArpExe($e) {
        if ($e.Icon) {
            $icon = ($e.Icon -replace ',\s*-?\d+$', '').Trim('"', ' ')
            if ($icon -match '\.exe$' -and $icon -notmatch $junk -and (Test-Path -LiteralPath $icon)) { return $icon }
        }
        return $null
    }
    # Проверить установку и записать в журнал, где лежит программа. $true, если нашлась.
    function Confirm-Installed($j) {
        $found = Find-ArpEntry $j
        if (-not $found.Count) { return $false }
        foreach ($e in ($found | Select-Object -First 2)) {
            $where = $(if ($e.Location) { $e.Location } elseif (Get-ArpExe $e) { Split-Path -Parent (Get-ArpExe $e) } else { 'папка не указана' })
            Log "    В «Программах и компонентах»: $($e.Name). Папка: $where"
            if ($e.Location -and -not (Test-Path -LiteralPath $e.Location)) { Log "    Внимание: папка $($e.Location) не существует." }
        }
        return $true
    }
    # Запасной путь: winget только скачивает установщик, а запускаем его мы
    function Install-ViaDownload($j, [bool]$silent) {
        $dir = Join-Path $env:TEMP ('BatchInstaller\wg-' + ($j.Id -replace '[^\w\.-]', '_'))
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Log '    Скачиваю установщик через winget download...'
        $code = Invoke-Captured $winget (@('download', '--id', $j.Id, '--exact', '--source', $j.WingetSource, '-d', "`"$dir`"",
                                         '--accept-package-agreements', '--accept-source-agreements') -join ' ')
        $file = Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -match '^\.(exe|msi)$' } | Sort-Object Length -Descending | Select-Object -First 1
        if (-not $file) { Log ('    Установщик не скачался (код 0x{0:X8}).' -f [int]$code); return $null }
        # Тихие ключи берём из apps.json (silentArgs), иначе открываем обычный мастер установки
        $argsLine = ''
        if ($silent -and $j.SilentArgs) { $argsLine = $j.SilentArgs }
        elseif ($silent -and $file.Extension -eq '.msi') { $argsLine = '/qn /norestart' }
        elseif ($silent) { Log '    Тихие ключи неизвестны, открываю мастер установки: пройдите его вручную.' }
        Send @{ Type = 'status'; Index = $j.Index; Status = 'Установка...' }
        Log "    Запуск: $($file.FullName) $argsLine"
        $rc = Invoke-Installer $file.FullName $argsLine
        Log "    Установщик завершился с кодом $rc"
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        return (Confirm-Installed $j)
    }

    $ok = 0; $fail = 0; $skip = 0; $reboot = $false; $cancelled = $false
    $total = $jobs.Count
    Log ('Начало установки: {0} шт., режим: {1}' -f $total, $(if ($silent) { 'тихий' } else { 'обычный' }))

    for ($n = 0; $n -lt $total; $n++) {
        $j = $jobs[$n]
        if ($sync.Cancel) {
            $cancelled = $true
            for ($k = $n; $k -lt $total; $k++) { Send @{ Type = 'status'; Index = $jobs[$k].Index; Status = 'Отменено' } }
            Log 'Установка отменена пользователем.'
            break
        }

        Send @{ Type = 'progress'; Value = $n; Max = $total; Text = ('[{0}/{1}] {2}' -f ($n + 1), $total, $j.Name) }
        Send @{ Type = 'status'; Index = $j.Index; Status = 'Установка...' }
        Log "=== $($j.Name) ==="
        $startBefore = Get-Links $startDirs
        $deskBefore  = Get-Links $deskDirs
        $result = 'Ошибка'

        try {
            if ($j.Source -eq 'winget') {
                if (-not $winget) { throw 'winget не найден в системе' }
                $a = @('install', '--id', $j.Id, '--exact', '--source', $j.WingetSource,
                       '--accept-package-agreements', '--accept-source-agreements')
                $a += $(if ($silent) { '--silent' } else { '--interactive' })
                if ($j.ExtraArgs) { $a += $j.ExtraArgs }
                $code = Invoke-Captured $winget ($a -join ' ')
                $hex = '{0:X8}' -f [int]$code
                switch ($hex) {
                    '00000000' { $result = 'Установлено' }
                    '8A15002B' { $result = 'Уже установлено' }
                    '8A150061' { $result = 'Уже установлено' }
                    '8A150109' { $result = 'Установлено (нужна перезагрузка)'; $reboot = $true }
                    '8A15010A' { $result = 'Установлено (нужна перезагрузка)'; $reboot = $true }
                    '8A150014' { $result = 'Не найдено в winget (проверьте id)' }
                    default    { $result = "Ошибка (код 0x$hex)" }
                }
                # winget может отчитаться об успехе, хотя установщик не запускался:
                # проверяем запись в «Программах и компонентах», при её отсутствии ставим сами
                if ($result.StartsWith('Установлено') -and $j.WingetSource -ne 'msstore' -and -not (Confirm-Installed $j)) {
                    Log '    winget сообщил об успехе, но программа не появилась в «Программах и компонентах».'
                    $ok2 = Install-ViaDownload $j $silent
                    if ($ok2 -eq $true)      { $result = 'Установлено' }
                    elseif ($null -eq $ok2)  { $result = 'Установлено (не подтверждено)'; Log '    Проверьте программу вручную.' }
                    else                     { $result = 'Ошибка (установщик не установил программу)' }
                }
            }
            elseif ($j.Source -eq 'url' -or $j.Source -eq 'local') {
                if ($j.Source -eq 'url') {
                    $dir = Join-Path $env:TEMP 'BatchInstaller'
                    New-Item -ItemType Directory -Force -Path $dir | Out-Null
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                    $ProgressPreference = 'SilentlyContinue'
                    $ua = [Microsoft.PowerShell.Commands.PSUserAgent]::Chrome
                    $url = $j.Url
                    # Свежая ссылка со страницы загрузки (urlPage + urlPattern), url остаётся запасной
                    if ($j.UrlPage -and $j.UrlPattern) {
                        try {
                            $html = (Invoke-WebRequest -Uri $j.UrlPage -UseBasicParsing -UserAgent $ua).Content
                            $mm = [regex]::Match($html, $j.UrlPattern)
                            if ($mm.Success) { $url = $mm.Value; Log "    Найдена свежая версия: $url" }
                            else { Log '    На странице загрузки ссылка не найдена, использую запасную.' }
                        } catch { Log "    Не удалось открыть страницу загрузки: $($_.Exception.Message)" }
                    }
                    if (-not $url) { throw 'Не указана ссылка для загрузки (url)' }
                    $name = $j.FileName
                    if (-not $name) { $name = [IO.Path]::GetFileName(([uri]$url).AbsolutePath) }
                    if (-not $name) { $name = "setup_$($j.Index).exe" }
                    $file = Join-Path $dir $name
                    Send @{ Type = 'status'; Index = $j.Index; Status = 'Загрузка...' }
                    Log "    Загрузка: $url"
                    Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing -UserAgent $ua
                    Send @{ Type = 'status'; Index = $j.Index; Status = 'Установка...' }
                } else {
                    $file = $(if ([IO.Path]::IsPathRooted($j.Path)) { $j.Path } else { Join-Path $root $j.Path })
                    if (-not (Test-Path -LiteralPath $file)) { throw "Файл не найден: $file" }
                }
                $argsLine = $(if ($silent) { $j.SilentArgs } else { $j.NormalArgs })
                if ($silent -and -not $argsLine -and $file -match '\.msi$') { $argsLine = '/qn /norestart' }
                if ($silent -and -not $argsLine) { Log '    Внимание: для этой программы не указаны silentArgs, установщик может показать окно.' }
                Log "    Запуск: $file $argsLine"
                $code = Invoke-Installer $file ([string]$argsLine)
                switch ($code) {
                    0       { $result = 'Установлено' }
                    3010    { $result = 'Установлено (нужна перезагрузка)'; $reboot = $true }
                    1641    { $result = 'Установлено (нужна перезагрузка)'; $reboot = $true }
                    default { $result = "Ошибка (код $code)" }
                }
            }
            else { throw "Неизвестный источник: $($j.Source)" }
        } catch {
            $result = 'Ошибка'
            Log "    $($_.Exception.Message)"
        }

        if     ($result.StartsWith('Установлено')) { $ok++ }
        elseif ($result.StartsWith('Уже'))         { $skip++ }
        else                                       { $fail++ }
        Send @{ Type = 'status'; Index = $j.Index; Status = $result }
        Log "    Итог: $result"
        if ($result.StartsWith('Установлено')) { Add-DesktopShortcut $j $startBefore $deskBefore }
    }

    Log ('Готово. Установлено: {0}, уже было: {1}, ошибок: {2}' -f $ok, $skip, $fail)
    Send @{ Type = 'done'; Ok = $ok; Skip = $skip; Fail = $fail; Reboot = $reboot; Cancelled = $cancelled; Total = $total }
}

# Поиск уже установленных программ через winget export
$CheckWorker = {
    param($sync, $winget)
    $tmp = Join-Path $env:TEMP ('winget-export-{0}.json' -f [guid]::NewGuid())
    try {
        $p = Start-Process -FilePath $winget -ArgumentList @('export', '-o', "`"$tmp`"", '--accept-source-agreements') -WindowStyle Hidden -PassThru
        $null = $p.Handle
        $p.WaitForExit()
        $ids = @()
        if (Test-Path -LiteralPath $tmp) {
            $data = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8 | ConvertFrom-Json
            $ids = @($data.Sources | ForEach-Object { $_.Packages } | ForEach-Object { [string]$_.PackageIdentifier })
        }
        $sync.Queue.Enqueue(@{ Type = 'installed'; Ids = $ids })
    } catch {
        $sync.Queue.Enqueue(@{ Type = 'installed'; Ids = @(); Error = $_.Exception.Message })
    } finally {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
}

# Установка winget, если его нет (сборки Windows с вырезанным App Installer)
$WingetSetupWorker = {
    param($sync, $logFile)
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    function Send([hashtable]$m) { $sync.Queue.Enqueue($m) }
    function Log([string]$t) {
        $line = '[{0:HH:mm:ss}] {1}' -f (Get-Date), $t
        Send @{ Type = 'log'; Text = $line }
        try { Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8 } catch { }
    }
    function Step([string]$t) { Send @{ Type = 'progress'; Value = 0; Max = 1; Text = $t }; Log $t }

    # Все места, где может лежать winget.exe: псевдоним приложения и сам пакет
    function Get-WingetCandidates {
        $list = New-Object System.Collections.Generic.List[string]
        $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
        if ([IO.File]::Exists($alias)) { $list.Add($alias) }
        $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd -and -not $list.Contains($cmd.Source)) { $list.Add($cmd.Source) }
        $pkgs = @(Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue) +
                @(Get-AppxPackage -AllUsers -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue)
        foreach ($p in ($pkgs | Where-Object { $_ } | Sort-Object { [version]$_.Version } -Descending)) {
            $exe = Join-Path $p.InstallLocation 'winget.exe'
            if ([IO.File]::Exists($exe) -and -not $list.Contains($exe)) { $list.Add($exe) }
        }
        Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | ForEach-Object { if (-not $list.Contains($_.FullName)) { $list.Add($_.FullName) } }
        $portable = Join-Path $env:ProgramData 'BatchInstaller\winget\winget.exe'
        if ([IO.File]::Exists($portable)) { $list.Add($portable) }
        return $list
    }

    # Запуск winget --version с таймаутом, без исключений на stderr
    function Invoke-Probe([string]$exe) {
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $exe
            $psi.Arguments = '--version'
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $p = [System.Diagnostics.Process]::Start($psi)
            $outTask = $p.StandardOutput.ReadToEndAsync()
            $errTask = $p.StandardError.ReadToEndAsync()
            if (-not $p.WaitForExit(30000)) { try { $p.Kill() } catch { }; return @{ Ok = $false; Info = 'нет ответа за 30 с' } }
            $out = ($outTask.Result + ' ' + $errTask.Result).Trim()
            if ($p.ExitCode -eq 0 -and $out -match 'v?\d+\.\d+') { return @{ Ok = $true; Info = $out } }
            return @{ Ok = $false; Info = ('код 0x{0:X8} {1}' -f $p.ExitCode, $out).Trim() }
        } catch { return @{ Ok = $false; Info = $_.Exception.Message } }
    }

    # Обновить PATH процесса из реестра (после установки пакета он устаревший)
    function Update-ProcessPath {
        $parts = @([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User'),
                   (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'))
        $env:Path = (($parts -join ';') -split ';' | Where-Object { $_ } | Select-Object -Unique) -join ';'
    }

    # Добавить в PATH папки зависимостей (VCLibs, UI.Xaml, WindowsAppRuntime):
    # без них winget.exe, запущенный напрямую из WindowsApps, не стартует
    function Add-DependencyPath {
        $arch = switch ($env:PROCESSOR_ARCHITECTURE) { 'ARM64' { 'Arm64' } 'x86' { 'X86' } default { 'X64' } }
        if ($env:PROCESSOR_ARCHITEW6432 -eq 'AMD64') { $arch = 'X64' }
        $names = 'Microsoft.VCLibs.140.00.UWPDesktop', 'Microsoft.VCLibs.140.00', 'Microsoft.UI.Xaml.*', 'Microsoft.WindowsAppRuntime.*'
        $dirs = foreach ($n in $names) {
            @(Get-AppxPackage -AllUsers -Name $n -ErrorAction SilentlyContinue) |
                Where-Object { [string]$_.Architecture -eq $arch -and $_.InstallLocation } |
                Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1 | ForEach-Object { $_.InstallLocation }
        }
        $add = @($dirs | Where-Object { $_ -and ($env:Path -split ';') -notcontains $_ })
        if ($add.Count) { $env:Path = (($add + $env:Path) -join ';') }
    }

    # Найти работающий winget; $Verbose = писать в лог, почему каждый вариант не подошёл
    function Test-Winget([bool]$Verbose = $false) {
        foreach ($c in (Get-WingetCandidates)) {
            $r = Invoke-Probe $c
            if ($r.Ok) { return $c }
            if ($Verbose) { Log "    $c : $($r.Info)" }
        }
        return $null
    }

    # Службы, без которых приложения из пакетов MSIX не запускаются.
    # В урезанных сборках их часто отключают: тогда winget установлен, но при запуске
    # «Доступ к этому файлу из системы отсутствует» и «No applicable license found».
    function Repair-AppServices {
        $services = [ordered]@{
            ClipSVC        = 'Служба лицензий клиента (ClipSVC)'
            LicenseManager = 'Служба Windows License Manager'
            AppXSvc        = 'Служба развёртывания AppX (AppXSVC)'
            StateRepository = 'Служба State Repository'
        }
        foreach ($name in $services.Keys) {
            $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$name"
            if (-not (Test-Path -LiteralPath $key)) { Log "    $($services[$name]): служба удалена из системы, починить нельзя."; continue }
            $start = (Get-ItemProperty -LiteralPath $key -Name Start -ErrorAction SilentlyContinue).Start
            if ($start -eq 4) {
                try {
                    # Set-Service для защищённых служб не работает, поэтому через реестр (3 = вручную, как в обычной Windows)
                    Set-ItemProperty -LiteralPath $key -Name Start -Value 3 -Type DWord -ErrorAction Stop
                    Log "    $($services[$name]) была отключена, включил (запуск вручную)."
                } catch { Log "    $($services[$name]) отключена, включить не удалось: $($_.Exception.Message)" }
            }
            if ($name -in 'ClipSVC', 'LicenseManager') {
                try {
                    $svc = Get-Service -Name $name -ErrorAction Stop
                    if ($svc.Status -ne 'Running') { Start-Service -Name $name -ErrorAction Stop; Log "    $($services[$name]): запущена." }
                } catch { Log "    $($services[$name]): не запускается ($($_.Exception.Message))" }
            }
        }
        # Политики, которые запрещают запуск приложений из Магазина (их не меняю, только сообщаю)
        $pol = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' -ErrorAction SilentlyContinue
        if ($pol -and $pol.DisableStoreApps -eq 1) {
            Log '    Внимание: включена политика DisableStoreApps (HKLM\SOFTWARE\Policies\Microsoft\WindowsStore). Она запрещает запуск приложений из Магазина, в том числе winget.'
        }
    }

    # Портативный winget: распаковать пакет в папку и запускать winget.exe оттуда,
    # без регистрации и лицензии. Используется, когда установленный пакет не стартует.
    function Install-PortableWinget([string]$bundle, [string[]]$deps, [string]$arch) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $target = Join-Path $env:ProgramData 'BatchInstaller\winget'
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        $tmpMsix = Join-Path $env:TEMP ('AppInstaller_{0}.msix' -f [guid]::NewGuid())
        $zip = [IO.Compression.ZipFile]::OpenRead($bundle)
        try {
            $entry = $zip.Entries | Where-Object { $_.Name -match "_$arch\.msix$" } | Select-Object -First 1
            if (-not $entry) { throw "в пакете нет AppInstaller для $arch" }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $tmpMsix, $true)
        } finally { $zip.Dispose() }
        try { [IO.Compression.ZipFile]::ExtractToDirectory($tmpMsix, $target) }
        finally { Remove-Item -LiteralPath $tmpMsix -ErrorAction SilentlyContinue }
        # Библиотеки зависимостей (VCLibs, WindowsAppRuntime) кладём рядом с winget.exe
        foreach ($d in $deps) {
            $z = [IO.Compression.ZipFile]::OpenRead($d)
            try {
                foreach ($e in $z.Entries) {
                    if ($e.FullName -notmatch '[/\\]' -and $e.Name -match '\.dll$') {
                        $out = Join-Path $target $e.Name
                        if (-not (Test-Path -LiteralPath $out)) { [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $out) }
                    }
                }
            } finally { $z.Dispose() }
        }
        $exe = Join-Path $target 'winget.exe'
        if (-not (Test-Path -LiteralPath $exe)) { throw 'после распаковки winget.exe не найден' }
        $r = Invoke-Probe $exe
        if ($r.Ok) { return $exe }
        Log "    Портативный winget: $($r.Info)"
        return $null
    }

    # После установки пакета: зарегистрировать, дождаться псевдонима winget и проверить
    function Wait-Winget([int]$Seconds = 45) {
        try { Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop } catch { }
        $deadline = (Get-Date).AddSeconds($Seconds)
        do {
            Update-ProcessPath
            $w = Test-Winget
            if ($w) { return $w }
            Send @{ Type = 'progress'; Value = 0; Max = 1; Text = 'winget: жду, пока Windows зарегистрирует команду winget...' }
            Start-Sleep -Seconds 3
        } while ((Get-Date) -lt $deadline)

        # Повторная регистрация из манифеста установленного пакета
        $pkg = @(Get-AppxPackage -AllUsers -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue) |
               Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
        if ($pkg) {
            Log "    Пакет: $($pkg.PackageFullName), статус: $($pkg.Status)"
            try {
                Add-AppxPackage -Register (Join-Path $pkg.InstallLocation 'AppxManifest.xml') -DisableDevelopmentMode -ForceApplicationShutdown -ErrorAction Stop
                Start-Sleep -Seconds 3
                $w = Test-Winget
                if ($w) { return $w }
            } catch { Log "    Перерегистрация: $($_.Exception.Message.Trim())" }
        } else { Log '    Пакет Microsoft.DesktopAppInstaller в системе не найден.' }

        # Запуск напрямую из папки пакета с зависимостями в PATH
        Add-DependencyPath
        $w = Test-Winget $true
        if ($w) { Log '    winget запускается напрямую из папки пакета.' }
        return $w
    }

    # Загрузка файла с отображением прогресса
    function Get-File([string]$url, [string]$file, [string]$title) {
        $req = [Net.HttpWebRequest]::Create($url)
        $req.UserAgent = 'BatchInstaller'
        $req.AllowAutoRedirect = $true
        $resp = $req.GetResponse()
        try {
            $total = $resp.ContentLength
            $in  = $resp.GetResponseStream()
            $out = [IO.File]::Create($file)
            try {
                $buf = New-Object byte[] 262144
                $done = 0L; $lastSend = [DateTime]::MinValue
                while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                    $out.Write($buf, 0, $n)
                    $done += $n
                    if (((Get-Date) - $lastSend).TotalMilliseconds -gt 300) {
                        $lastSend = Get-Date
                        $mb = '{0:N1}' -f ($done / 1MB)
                        if ($total -gt 0) {
                            Send @{ Type = 'progress'; Value = $done; Max = $total; Text = ('{0}: {1} из {2:N1} МБ' -f $title, $mb, ($total / 1MB)) }
                        } else {
                            Send @{ Type = 'progress'; Value = 0; Max = 1; Text = "${title}: $mb МБ" }
                        }
                    }
                }
            } finally { $out.Dispose(); $in.Dispose() }
        } finally { $resp.Close() }
        Log ('    Загружено: {0} ({1:N1} МБ)' -f [IO.Path]::GetFileName($file), ((Get-Item -LiteralPath $file).Length / 1MB))
    }

    $result = $null
    try {
        Log 'winget не найден. Начинаю автоматическую установку.'

        $build = [Environment]::OSVersion.Version.Build
        if ($build -lt 17763) { throw "winget работает только на Windows 10 1809 (сборка 17763) и новее, у вас сборка $build." }
        if (-not (Get-Command Add-AppxPackage -ErrorAction SilentlyContinue)) {
            throw 'В системе нет модуля Appx (Add-AppxPackage): установка пакетов MSIX вырезана из сборки.'
        }

        Step 'winget: проверяю службы лицензий и AppX...'
        Repair-AppServices

        # 1. Пакет уже есть, но не зарегистрирован для пользователя
        Step 'winget: пробую зарегистрировать «Установщик приложений»...'
        try {
            Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop
        } catch { Log '    Пакет в системе не найден.' }
        $result = Test-Winget
        if (-not $result -and (Get-AppxPackage -AllUsers -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue)) {
            Log '    Пакет есть, но winget не отвечает. Пробую починить регистрацию.'
            $result = Wait-Winget 15
        }

        # 2. Загрузка App Installer и зависимостей (VCLibs, UI.Xaml) с GitHub
        if (-not $result) {
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                $arch = switch ($env:PROCESSOR_ARCHITECTURE) { 'ARM64' { 'arm64' } 'x86' { 'x86' } default { 'x64' } }
                if ($env:PROCESSOR_ARCHITEW6432 -eq 'AMD64') { $arch = 'x64' }
                $dir = Join-Path $env:TEMP 'BatchInstaller\winget'
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
                New-Item -ItemType Directory -Force -Path $dir | Out-Null

                Step 'winget: ищу последнюю версию на GitHub...'
                $base = 'https://github.com/microsoft/winget-cli/releases/latest/download'
                $bundleUrl = "$base/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
                $depsUrl   = "$base/DesktopAppInstaller_Dependencies.zip"
                $licUrl    = $null
                try {
                    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' -UserAgent 'BatchInstaller' -UseBasicParsing
                    Log "    Версия: $($rel.tag_name)"
                    foreach ($a in $rel.assets) {
                        if ($a.name -like '*.msixbundle')                   { $bundleUrl = $a.browser_download_url }
                        elseif ($a.name -eq 'DesktopAppInstaller_Dependencies.zip') { $depsUrl = $a.browser_download_url }
                        elseif ($a.name -like '*License*.xml')              { $licUrl = $a.browser_download_url }
                    }
                } catch { Log "    GitHub API недоступен ($($_.Exception.Message)), использую прямые ссылки." }

                $bundle = Join-Path $dir 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
                $depsZip = Join-Path $dir 'Dependencies.zip'
                Get-File $depsUrl $depsZip 'winget: загрузка зависимостей'
                Get-File $bundleUrl $bundle 'winget: загрузка App Installer'
                $lic = $null
                if ($licUrl) {
                    $lic = Join-Path $dir 'License.xml'
                    try { Get-File $licUrl $lic 'winget: загрузка лицензии' } catch { $lic = $null }
                }

                Step 'winget: распаковка зависимостей...'
                $depsDir = Join-Path $dir 'deps'
                Expand-Archive -LiteralPath $depsZip -DestinationPath $depsDir -Force
                $deps = @(Get-ChildItem -Path $depsDir -Recurse -File |
                          Where-Object { $_.Extension -match '^\.(appx|msix)$' -and $_.FullName -match "[\\_]$arch[\\_.]" } | ForEach-Object { $_.FullName })
                foreach ($d in $deps) { Log "    Зависимость: $([IO.Path]::GetFileName($d))" }

                # Зависимости ставим по одной: уже установленные более новые версии не мешают
                Step 'winget: установка зависимостей (VCLibs, UI.Xaml)...'
                foreach ($d in $deps) {
                    try { Add-AppxPackage -Path $d -ErrorAction Stop }
                    catch { Log "    $([IO.Path]::GetFileName($d)): $($_.Exception.Message.Trim())" }
                }

                Step 'winget: установка «Установщика приложений»...'
                $provisioned = $false
                try {
                    # Для всех пользователей (нужны права администратора, они у нас есть)
                    $pp = @{ Online = $true; PackagePath = $bundle; ErrorAction = 'Stop' }
                    if ($deps.Count) { $pp.DependencyPackagePath = $deps }
                    if ($lic) { $pp.LicensePath = $lic } else { $pp.SkipLicense = $true }
                    Add-AppxProvisionedPackage @pp | Out-Null
                    $provisioned = $true
                    Log '    Пакет подготовлен для всех пользователей.'
                } catch { Log "    Add-AppxProvisionedPackage: $($_.Exception.Message.Trim())" }

                try {
                    $ap = @{ Path = $bundle; ForceApplicationShutdown = $true; ErrorAction = 'Stop' }
                    if ($deps.Count) { $ap.DependencyPath = $deps }
                    Add-AppxPackage @ap
                } catch {
                    if ($provisioned) {
                        try { Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop }
                        catch { Log "    Регистрация: $($_.Exception.Message.Trim())" }
                    } else { Log "    Add-AppxPackage: $($_.Exception.Message.Trim())" }
                }
                $result = Wait-Winget
                if (-not $result) { Log '    После установки с GitHub winget не отвечает (причины выше).' }

                # 2б. Портативный winget из того же пакета
                if (-not $result) {
                    Step 'winget: пробую портативный вариант (без регистрации пакета)...'
                    try {
                        $result = Install-PortableWinget $bundle $deps $arch
                        if ($result) { Log "    Портативный winget работает: $result" }
                    } catch { Log "    Портативный winget: $($_.Exception.Message)" }
                }
            } catch { Log "    Установка с GitHub не удалась: $($_.Exception.Message)" }
            finally { if ($dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue } }
        }

        # 3. Запасной способ: официальный модуль Microsoft.WinGet.Client из PowerShell Gallery
        if (-not $result) {
            try {
                Step 'winget: запасной способ, модуль Microsoft.WinGet.Client...'
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue | Where-Object { $_.Version -ge [version]'2.8.5.201' })) {
                    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ForceBootstrap -Scope AllUsers | Out-Null
                }
                Install-Module -Name Microsoft.WinGet.Client -Force -AllowClobber -Scope AllUsers -Repository PSGallery -ErrorAction Stop
                Import-Module Microsoft.WinGet.Client -Force
                Step 'winget: Repair-WinGetPackageManager (загрузка и установка)...'
                Repair-WinGetPackageManager -AllUsers -Latest -Force | Out-Null
                $result = Wait-Winget
            } catch { Log "    Модуль Microsoft.WinGet.Client: $($_.Exception.Message)" }
        }
    } catch {
        Log "    $($_.Exception.Message)"
    }

    if ($result) {
        $ver = try { & $result --version 2>$null | Select-Object -First 1 } catch { '' }
        Log "winget установлен: $ver ($result)"
    } else {
        Log 'Не удалось установить winget автоматически. Программы с источником winget будут пропущены, url и local установятся как обычно.'
        Log 'Установите App Installer вручную с https://aka.ms/getwinget и перезапустите программу (или нажмите на надпись про winget внизу, чтобы повторить).'
    }
    Send @{ Type = 'winget'; Path = $result }
}

# ---------------------------------------------------------------------------
# Вспомогательные функции UI
# ---------------------------------------------------------------------------
function Write-UiLog([string]$Text) {
    $ui.LogBox.AppendText($Text + "`r`n")
    $ui.LogBox.ScrollToEnd()
}

function Update-Count {
    $sel = @($Items | Where-Object { $_.IsSelected }).Count
    $ui.CountText.Text = "$sel / $($Items.Count)"
    $ui.PageNum.Text   = '{0:000}' -f $sel
}

# Фильтр списка: поиск + выбранная категория
function Update-Filter {
    $text = $ui.SearchBox.Text.Trim()
    $cat  = $script:CatFilter
    if (-not $text -and -not $cat) { $View.Filter = $null; return }
    $View.Filter = [Predicate[object]]({
        param($o)
        if ($cat -and $o.Category -ne $cat) { return $false }
        if (-not $text) { return $true }
        $o.Name -like "*$text*" -or $o.Description -like "*$text*" -or $o.Category -like "*$text*" -or $o.Id -like "*$text*"
    }.GetNewClosure())
}

function Set-Busy([bool]$Busy) {
    $script:Busy = $Busy
    foreach ($b in 'BtnAll', 'BtnNone', 'BtnDefault', 'BtnCheck', 'BtnSave', 'BtnInstall', 'ChkSilent', 'RbWizard') { $ui[$b].IsEnabled = -not $Busy }
    $ui.BtnCancel.IsEnabled = $Busy
}

function Get-VisibleItems { @($View | ForEach-Object { $_ }) }

function Invoke-Message($m) {
    switch ($m.Type) {
        'log'      { Write-UiLog $m.Text }
        'status'   { $Items[[int]$m.Index].Status = $m.Status }
        'progress' {
            $ui.Progress.Maximum = [Math]::Max(1, $m.Max)
            $ui.Progress.Value   = $m.Value
            $ui.ProgressText.Text = $m.Text
        }
        'done' {
            $ui.Progress.Value = $ui.Progress.Maximum
            $summary = "Установлено: $($m.Ok), уже было: $($m.Skip), ошибок: $($m.Fail)"
            $ui.ProgressText.Text = $(if ($m.Cancelled) { "Отменено. $summary" } else { "Готово. $summary" })
            Set-Busy $false
            Clear-Workers
            $msg = $summary
            if ($m.Reboot) { $msg += "`n`nДля завершения установки некоторых программ нужна перезагрузка." }
            $icon = $(if ($m.Fail -gt 0) { 'Warning' } else { 'Information' })
            [System.Windows.MessageBox]::Show($Window, $msg, 'Установка завершена', 'OK', $icon) | Out-Null
        }
        'winget' {
            Set-Busy $false
            Clear-Workers
            $script:Winget = $m.Path
            Add-PortableWingetToPath
            Update-WingetInfo
            $ui.Progress.Value = 0
            $ui.ProgressText.Text = $(if ($m.Path) { 'Готово к установке' } else { 'winget не установлен: доступны только программы из url и local' })
        }
        'installed' {
            Set-Busy $false
            Clear-Workers
            if ($m.Error) { Write-UiLog "Не удалось получить список установленных: $($m.Error)"; $ui.ProgressText.Text = 'Готово к установке'; return }
            $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($id in $m.Ids) { [void]$set.Add($id) }
            $found = 0
            foreach ($it in $Items) {
                if ($it.Source -eq 'winget' -and $set.Contains($it.Id)) {
                    $it.Status = 'Уже установлено'
                    $it.IsSelected = $false
                    $found++
                }
            }
            Write-UiLog "Найдено уже установленных программ из списка: $found (с них снята галочка)."
            $ui.ProgressText.Text = 'Готово к установке'
        }
    }
}

# ---------------------------------------------------------------------------
# Обработчики событий
# ---------------------------------------------------------------------------
foreach ($it in $Items) { $it.add_PropertyChanged({ param($s, $e) if ($e.PropertyName -eq 'IsSelected') { Update-Count } }) }

$ui.SearchBox.Add_TextChanged({
    $ui.SearchHint.Visibility = $(if ($ui.SearchBox.Text) { 'Collapsed' } else { 'Visible' })
    Update-Filter
})

$ui.CatList.Add_SelectionChanged({
    $sel = $ui.CatList.SelectedItem
    $script:CatFilter = $(if ($sel) { $sel.Key } else { $null })
    Update-Filter
})

# Своя рамка окна: свернуть, закрыть, отступ при развороте на весь экран
$ui.BtnMin.Add_Click({ $Window.WindowState = 'Minimized' })
$ui.BtnClose.Add_Click({ $Window.Close() })
$Window.Add_StateChanged({
    $ui.Root.Margin = $(if ($Window.WindowState -eq 'Maximized') { New-Object System.Windows.Thickness 7 } else { New-Object System.Windows.Thickness 0 })
})

$ui.BtnAll.Add_Click({ foreach ($it in Get-VisibleItems) { $it.IsSelected = $true } })
$ui.BtnNone.Add_Click({ foreach ($it in Get-VisibleItems) { $it.IsSelected = $false } })
$ui.BtnDefault.Add_Click({ foreach ($it in $Items) { $it.IsSelected = $it.DefaultChecked } })

$ui.BtnSave.Add_Click({
    $keys = @($Items | Where-Object { $_.IsSelected } | ForEach-Object { $_.Key })
    ConvertTo-Json -InputObject $keys | Set-Content -LiteralPath $SelectionPath -Encoding UTF8
    Write-UiLog "Выбор сохранён ($($keys.Count) шт.) в $SelectionPath. Он загрузится при следующем запуске."
})

$ui.BtnEdit.Add_Click({
    Start-Process notepad.exe -ArgumentList "`"$ConfigPath`""
    Write-UiLog 'После сохранения apps.json перезапустите программу, чтобы увидеть изменения.'
})

# Кнопка «выбрать / снять группу» в заголовке категории
$ui.AppGrid.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($s, $e)
    $btn = $e.OriginalSource
    if ($btn -is [System.Windows.Controls.Button] -and $btn.Tag -is [string]) {
        $group = @(Get-VisibleItems | Where-Object { $_.Category -eq $btn.Tag })
        $allSelected = @($group | Where-Object { -not $_.IsSelected }).Count -eq 0
        foreach ($it in $group) { $it.IsSelected = -not $allSelected }
        $e.Handled = $true
    }
})

$ui.BtnCheck.Add_Click({
    if (-not $Winget) { Write-UiLog 'winget не найден, проверка невозможна.'; return }
    Set-Busy $true
    $ui.ProgressText.Text = 'Поиск установленных программ...'
    Write-UiLog 'Получаю список установленных программ через winget...'
    Start-Worker $CheckWorker @($Sync, $Winget)
})

$ui.BtnInstall.Add_Click({
    $selected = @($Items | Where-Object { $_.IsSelected })
    if ($selected.Count -eq 0) {
        [System.Windows.MessageBox]::Show($Window, 'Не выбрано ни одной программы.', 'Пакетная установка', 'OK', 'Information') | Out-Null
        return
    }
    $silent = [bool]$ui.ChkSilent.IsChecked
    $jobs = foreach ($it in $selected) {
        $it.Status = 'В очереди'
        @{
            Index = $it.Index; Name = $it.Name; Source = $it.Source; Id = $it.Id; WingetSource = $it.WingetSource
            Url = $it.Url; UrlPage = $it.UrlPage; UrlPattern = $it.UrlPattern; Path = $it.Path; FileName = $it.FileName
            SilentArgs = $it.SilentArgs; NormalArgs = $it.NormalArgs; ExtraArgs = $it.ExtraArgs
            Shortcut = ($config.apps[$it.Index].shortcut -ne $false); Exe = [string]$config.apps[$it.Index].exe
        }
    }
    $jobs = @($jobs)
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $logFile = Join-Path $LogDir ('install-{0:yyyy-MM-dd_HH-mm-ss}.log' -f (Get-Date))
    Write-UiLog "Лог сохраняется в $logFile"
    $Sync.Cancel = $false
    $ui.Progress.Value = 0
    Set-Busy $true
    Start-Worker $InstallWorker @($Sync, $jobs, $silent, $Winget, $Root, $logFile)
})

$ui.BtnCancel.Add_Click({
    $Sync.Cancel = $true
    $ui.BtnCancel.IsEnabled = $false
    $ui.ProgressText.Text = 'Отмена: дожидаюсь окончания текущей программы...'
    Write-UiLog 'Отмена запрошена. Текущая программа будет доустановлена, остальные пропущены.'
})

$Timer = New-Object System.Windows.Threading.DispatcherTimer
$Timer.Interval = [TimeSpan]::FromMilliseconds(150)
$Timer.Add_Tick({
    $m = $null
    while ($Sync.Queue.TryDequeue([ref]$m)) { Invoke-Message $m }
})

$Window.Add_Closing({
    param($s, $e)
    if ($script:Busy) {
        $r = [System.Windows.MessageBox]::Show($Window, "Установка ещё идёт. Закрыть окно?`nТекущая программа доустановится, остальные будут пропущены.", 'Пакетная установка', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { $e.Cancel = $true; return }
        $Sync.Cancel = $true
    }
    $Timer.Stop()
})

# ---------------------------------------------------------------------------
# Запуск
# ---------------------------------------------------------------------------
# Портативный winget (C:\ProgramData\BatchInstaller\winget) добавляем в системный PATH,
# чтобы команда winget работала и в консоли. Системный PATH идёт раньше пользовательского,
# поэтому он перекрывает неработающий псевдоним из %LOCALAPPDATA%\Microsoft\WindowsApps.
function Add-PortableWingetToPath {
    $dir = Join-Path $env:ProgramData 'BatchInstaller\winget'
    if (-not $script:Winget -or -not $script:Winget.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase)) { return }
    try {
        $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        if (($machine -split ';') -notcontains $dir) {
            [Environment]::SetEnvironmentVariable('Path', ($machine.TrimEnd(';') + ';' + $dir), 'Machine')
            Write-UiLog "Портативный winget добавлен в системный PATH ($dir). В новых окнах консоли команда winget будет работать."
        }
    } catch { Write-UiLog "Не удалось добавить winget в PATH: $($_.Exception.Message)" }
}

function Update-WingetInfo {
    if ($script:Winget) {
        $ver = try { (& $script:Winget --version 2>$null | Select-Object -First 1) } catch { '' }
        $ui.WingetInfo.Text = "winget $ver"
        $ui.WingetInfo.Foreground = $Window.FindResource('Muted')
        $ui.WingetInfo.Cursor = $null
        $ui.WingetInfo.ToolTip = $null
    } else {
        $ui.WingetInfo.Text = 'winget не найден: нажмите, чтобы установить'
        $ui.WingetInfo.Foreground = '#C62828'
        $ui.WingetInfo.Cursor = [System.Windows.Input.Cursors]::Hand
        $ui.WingetInfo.ToolTip = 'Скачать и установить winget (App Installer) с GitHub'
    }
}

# Автоматическая установка winget в фоне, окно при этом остаётся отзывчивым
function Start-WingetSetup {
    if ($script:Busy -or $script:Winget) { return }
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $logFile = Join-Path $LogDir ('winget-setup-{0:yyyy-MM-dd_HH-mm-ss}.log' -f (Get-Date))
    Set-Busy $true
    $ui.BtnCancel.IsEnabled = $false
    $ui.WingetInfo.Text = 'winget: идёт установка...'
    $ui.WingetInfo.Cursor = $null
    Write-UiLog "Лог установки winget: $logFile"
    Start-Worker $WingetSetupWorker @($Sync, $logFile)
}

$ui.WingetInfo.Add_MouseLeftButtonUp({ if (-not $script:Winget) { Start-WingetSetup } })

Update-WingetInfo
Add-PortableWingetToPath
if (-not $Winget) { $Window.Add_ContentRendered({ Start-WingetSetup }) }
$ru = [Globalization.CultureInfo]::GetCultureInfo('ru-RU')
$now = Get-Date
$day = $now.ToString('ddd', $ru)
$ui.HeaderDay.Text  = $day.Substring(0, 1).ToUpper() + $day.Substring(1)
$ui.HeaderDate.Text = $now.ToString('d MMMM', $ru)
$ui.HeaderYear.Text = $now.ToString('yyyy')
Update-Count
$Timer.Start()
[void]$Window.ShowDialog()
