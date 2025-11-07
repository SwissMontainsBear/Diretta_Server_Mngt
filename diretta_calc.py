#!/usr/bin/env python3
"""
Diretta DDS Configuration Calculator with Historical Log Analysis
Optimized for systems with high-quality reference clocks (e.g., Mutec REF10 SE120)

Key Focus: Clock STABILITY (jitter/phase noise), not just accuracy
"""

import argparse
import re
import subprocess
from pathlib import Path
import numpy as np
import time
import sys
import signal

class DirettaCalculator:
    """Calculate Diretta DDS configuration parameters"""
    
    # Ethernet frame overhead
    ETH_HEADER = 14
    DIRETTA_HEADER = 2
    VLAN_OVERHEAD = 4
    FCS = 4
    
    def __init__(self, mtu: int = 9024):
        self.mtu = mtu
        self.overhead = self.ETH_HEADER + self.DIRETTA_HEADER + self.VLAN_OVERHEAD
        self.available_payload = mtu - self.overhead
        
    def calculate_frame_params(self, sample_rate: int, is_dsd: bool = True):
        """Calculate frame parameters for a given sample rate"""
        # Bytes per sample (stereo)
        if is_dsd:
            bytes_per_sample = 0.25
        else:
            bytes_per_sample = 6
        
        # Calculate samples that fit in available payload
        audio_bytes_max = (int(self.available_payload / 8) * 8)
        samples_per_frame = int(audio_bytes_max / bytes_per_sample)
        audio_bytes = int(samples_per_frame * bytes_per_sample)
        
        # Calculate cycle time
        cycle_time_us = (samples_per_frame / sample_rate) * 1_000_000
        packet_rate_hz = sample_rate / samples_per_frame
        total_frame_size = self.ETH_HEADER + self.DIRETTA_HEADER + audio_bytes + self.FCS
        
        return {
            'sample_rate': sample_rate,
            'sample_rate_mhz': sample_rate / 1_000_000,
            'samples_per_frame': samples_per_frame,
            'audio_bytes': audio_bytes,
            'total_frame_size': total_frame_size,
            'cycle_time_us': cycle_time_us,
            'cycle_time_ms': cycle_time_us / 1000,
            'packet_rate_hz': packet_rate_hz,
            'bytes_per_sample': bytes_per_sample,
            'is_dsd': is_dsd,
        }
    
    def calculate_cycle_time_for_48k(self, is_dsd: bool = True):
        """Calculate CycleTime based on 48kHz base rate"""
        base_rate = 48000
        multiplier = 256 if is_dsd else 8
        sample_rate = base_rate * multiplier
        params = self.calculate_frame_params(sample_rate, is_dsd)
        
        # Round to nearest 5 μs for cleaner values
        cycle_time = int(round(params['cycle_time_us'] / 5) * 5)
        
        return cycle_time, params


def detect_network_mtu(interface: str = None) -> dict:
    """
    Detect MTU settings for network interfaces.
    If interface is specified, checks only that interface.
    Otherwise, checks all interfaces and finds the one with highest MTU.
    
    Returns dict with:
        - interface: name of the interface
        - mtu: MTU value
        - all_interfaces: dict of all interface MTUs (if no specific interface requested)
    """
    result = {
        'interface': None,
        'mtu': None,
        'all_interfaces': {},
        'method': None
    }
    
    try:
        # Try using 'ip' command (modern Linux)
        cmd = "ip -o link show"
        output = subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.DEVNULL)
        
        for line in output.strip().split('\n'):
            # Parse: "2: enp5s0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 9000 ..."
            match = re.search(r'^\d+:\s+(\S+):.*mtu\s+(\d+)', line)
            if match:
                iface_name = match.group(1)
                iface_mtu = int(match.group(2))
                
                # Skip loopback
                if iface_name == 'lo':
                    continue
                
                result['all_interfaces'][iface_name] = iface_mtu
                
                # If specific interface requested, check for match
                if interface and iface_name == interface:
                    result['interface'] = iface_name
                    result['mtu'] = iface_mtu
                    result['method'] = 'ip_command'
                    return result
        
        # If no specific interface requested, find the one with highest MTU
        if not interface and result['all_interfaces']:
            best_iface = max(result['all_interfaces'].items(), key=lambda x: x[1])
            result['interface'] = best_iface[0]
            result['mtu'] = best_iface[1]
            result['method'] = 'ip_command_auto'
            return result
            
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass
    
    try:
        # Fallback: try ifconfig (older systems)
        if interface:
            cmd = f"ifconfig {interface}"
        else:
            cmd = "ifconfig"
        
        output = subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.DEVNULL)
        
        # Parse ifconfig output
        current_iface = None
        for line in output.split('\n'):
            # Interface name line
            iface_match = re.match(r'^(\S+):', line)
            if iface_match:
                current_iface = iface_match.group(1)
                continue
            
            # MTU line
            if current_iface and 'mtu' in line.lower():
                mtu_match = re.search(r'mtu[:\s]+(\d+)', line, re.IGNORECASE)
                if mtu_match:
                    iface_mtu = int(mtu_match.group(1))
                    
                    if current_iface == 'lo':
                        continue
                    
                    result['all_interfaces'][current_iface] = iface_mtu
                    
                    if interface and current_iface == interface:
                        result['interface'] = current_iface
                        result['mtu'] = iface_mtu
                        result['method'] = 'ifconfig'
                        return result
        
        # If no specific interface requested, find highest MTU
        if not interface and result['all_interfaces']:
            best_iface = max(result['all_interfaces'].items(), key=lambda x: x[1])
            result['interface'] = best_iface[0]
            result['mtu'] = best_iface[1]
            result['method'] = 'ifconfig_auto'
            return result
            
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass
    
    try:
        # Last resort: try reading from /sys/class/net/
        net_path = Path('/sys/class/net')
        if net_path.exists():
            for iface_path in net_path.iterdir():
                iface_name = iface_path.name
                
                if iface_name == 'lo':
                    continue
                
                mtu_file = iface_path / 'mtu'
                if mtu_file.exists():
                    iface_mtu = int(mtu_file.read_text().strip())
                    result['all_interfaces'][iface_name] = iface_mtu
                    
                    if interface and iface_name == interface:
                        result['interface'] = iface_name
                        result['mtu'] = iface_mtu
                        result['method'] = 'sysfs'
                        return result
            
            # If no specific interface requested, find highest MTU
            if not interface and result['all_interfaces']:
                best_iface = max(result['all_interfaces'].items(), key=lambda x: x[1])
                result['interface'] = best_iface[0]
                result['mtu'] = best_iface[1]
                result['method'] = 'sysfs_auto'
                return result
    except Exception:
        pass
    
    # If we get here and no MTU was found, return None
    if not result['mtu']:
        result['method'] = 'failed'
    
    return result


class DirettaMonitor:
    """Analyze Diretta operation for jitter and buffer stability using historical logs."""

    def __init__(self, service_name: str = "diretta_sync_host", cycle_time_us: float = None):
        self.service_name = service_name
        self.cycle_time_us = cycle_time_us

    def analyze_recent_logs(self, num_lines: int) -> str:
        """Analyzes the last N log entries from journalctl for stability."""
        report = []
        # Add interpretation guide
        report.append("=" * 100)
        report.append("INTERPRETATION GUIDE:")
        report.append("-" * 100)
        report.append("NETWORK JITTER (Percentage of Cycle Time):")
        report.append("  IQR < 0.1%  : Exceptional - Reference-grade network timing")
        report.append("  IQR < 0.5%  : Excellent - Very high quality network")
        report.append("  IQR < 1.0%  : Very Good - Good network stability")
        report.append("  IQR < 2.0%  : Good - Acceptable for audio streaming")
        report.append("  IQR < 5.0%  : Fair - May benefit from network optimization")
        report.append("  IQR ≥ 5.0%  : Poor - Investigate network issues (switch config, cables)")
        report.append("")
        report.append("BUFFER CORRECTION STABILITY:")
        report.append("  IQR < 0.005 : Exceptional - Clocks very well matched")
        report.append("  IQR < 0.010 : Excellent - Good clock matching or PTP working well")
        report.append("  IQR < 0.020 : Good - Acceptable clock stability")
        report.append("  IQR ≥ 0.020 : Poor - Significant clock mismatch, consider PTP")
        report.append("")
        report.append("WHAT THESE METRICS TELL YOU:")
        report.append("  • Low network jitter: Network path is stable (good switches, cables)")
        report.append("  • Low buffer corrections: Clocks are well matched (good crystal OR PTP active)")
        report.append("  • High buffer corrections: Clock drift present - Diretta is compensating")
        report.append("")
        report.append("CONTEXT FOR YOUR SYSTEM:")
        report.append("  • Your Mutec REF10 SE120 provides exceptional reference at the DAC")
        report.append("  • Server motherboard clock: Typically 20-100 ppm drift without PTP")
        report.append("  • With PTP: Server can sync to within < 1 ppm of DAC clock")
        report.append("  • Correction values show: How hard Diretta works to compensate")
        report.append("")
        report.append("RECOMMENDATION:")
        report.append("  If correction IQR > 0.020:")
        report.append("    → Enable PTP synchronization between server and DAC")
        report.append("    → This will reduce Diretta's correction workload")
        report.append("    → Result: More stable playback, less CPU overhead")
        report.append(" " * 100)
        report.append("=" * 100)
        report.append(f"DIRETTA STABILITY ANALYSIS (LAST {num_lines:,} LOG ENTRIES)")
        report.append("=" * 100)

        report.append(f"Service: {self.service_name}")
        
        from datetime import datetime
        report.append(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        
        # Try to detect cycle time from config if not provided
        if self.cycle_time_us is None:
            self.cycle_time_us = self._detect_cycle_time()
        
        if self.cycle_time_us:
            report.append(f"Expected CycleTime: {self.cycle_time_us:.1f} μs (from configuration)")
        else:
            report.append(f"Expected CycleTime: Will be detected from logs")
        
        report.append("Analyzing logs...")

        try:
            cmd = f"journalctl -u {self.service_name} -n {num_lines} --no-pager"
            logs = subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.DEVNULL)
        except subprocess.CalledProcessError:
            logs = ""

        if not logs:
            report.append(f"✗ No logs found for service '{self.service_name}'.")
            return "\n".join(report)

        report.append("✓ Logs captured. Performing analysis.")
        report.append("")

        # Parse the actual log format: "info rcv X Y.YYYY Z.ZZZZ W.WWWW cy=PPPPPPPPPP"
        parsed_data = self.parse_diretta_logs(logs)
        
        if not parsed_data:
            report.append("✗ Could not parse log data. Check log format.")
            return "\n".join(report)
        
        cycle_times = parsed_data['cycle_times']
        buffer_diff = parsed_data['buffer_diff']
        buffer_avg = parsed_data['buffer_avg']
        correction = parsed_data['correction']
        
        report.append(f"✓ Parsed {len(cycle_times):,} log entries")
        report.append("")

        # Auto-detect cycle time if not set
        if not self.cycle_time_us and cycle_times:
            self.cycle_time_us = np.mean(cycle_times)
            report.append(f"✓ Detected CycleTime: {self.cycle_time_us:.1f} μs (from log data)")
            report.append("")

        # 1. Analyze Cycle Time (Network Jitter)
        if cycle_times:
            cycle_stats = self.analyze_stability(cycle_times, "Cycle Time")
            
            # Calculate percentage-based metrics
            if self.cycle_time_us:
                stdev_pct = (cycle_stats['stdev'] / self.cycle_time_us) * 100
                iqr_pct = (cycle_stats['iqr'] / self.cycle_time_us) * 100
                range_pct = (cycle_stats['range'] / self.cycle_time_us) * 100
                
                # Quality assessment based on PERCENTAGE of cycle time
                if iqr_pct < 0.1:
                    quality_assessment = "✓ Exceptional (IQR < 0.1% of cycle)"
                elif iqr_pct < 0.5:
                    quality_assessment = "✓ Excellent (IQR < 0.5% of cycle)"
                elif iqr_pct < 1.0:
                    quality_assessment = "✓ Very Good (IQR < 1.0% of cycle)"
                elif iqr_pct < 2.0:
                    quality_assessment = "✓ Good (IQR < 2.0% of cycle)"
                elif iqr_pct < 5.0:
                    quality_assessment = "○ Fair (IQR < 5.0% of cycle)"
                else:
                    quality_assessment = "✗ Poor (IQR ≥ 5.0% of cycle)"
                
                report.append("1. NETWORK TIMING JITTER (from 'cy=...' values)")
                report.append("-" * 100)
                report.append(f"   Assessment:            {quality_assessment}")
                report.append(f"   Samples found:         {cycle_stats['count']:,}")
                report.append(f"   Expected Cycle Time:   {self.cycle_time_us:.1f} μs")
                report.append(f"   Measured Average:      {cycle_stats['mean']:.3f} μs (offset: {cycle_stats['mean'] - self.cycle_time_us:+.3f} μs)")
                report.append(f"")
                report.append(f"   PERCENTAGE-BASED METRICS (% of cycle time):")
                report.append(f"   Standard Deviation:    {cycle_stats['stdev']:.3f} μs ({stdev_pct:.3f}%)")
                report.append(f"   Interquartile Range:   {cycle_stats['iqr']:.3f} μs ({iqr_pct:.3f}%) ← primary jitter metric")
                report.append(f"   Peak-to-Peak Range:    {cycle_stats['range']:.3f} μs ({range_pct:.3f}%)")
                report.append(f"")
                report.append(f"   ABSOLUTE VALUES:")
                report.append(f"   Min / Max Cycle:       {cycle_stats['min']:.3f} μs / {cycle_stats['max']:.3f} μs")
            
            report.append("-" * 100)
        else:
            report.append(f"1. NETWORK TIMING JITTER: No 'cy=' data found.")

        report.append("")

        # 2. Analyze Buffer Management (Correction Values)
        if correction and len(correction) >= 10:
            correction_stats = self.analyze_stability(correction, "Correction Values")
            
            # Assess buffer stability based on correction magnitude and variability
            abs_mean_correction = abs(correction_stats['mean'])
            correction_range = correction_stats['range']
            
            if correction_stats['iqr'] < 0.001 and abs_mean_correction < 0.005:
                quality = "✓ Exceptional - Minimal buffer adjustments needed"
            elif correction_stats['iqr'] < 0.005 and abs_mean_correction < 0.010:
                quality = "✓ Excellent - Very stable buffer management"
            elif correction_stats['iqr'] < 0.010 and abs_mean_correction < 0.020:
                quality = "✓ Good - Stable buffer management"
            elif correction_stats['iqr'] < 0.020:
                quality = "○ Fair - Moderate buffer adjustments"
            else:
                quality = "✗ Poor - Frequent large buffer corrections (possible clock mismatch)"
            
            report.append("2. BUFFER MANAGEMENT STABILITY (from correction values)")
            report.append("-" * 100)
            report.append(f"   Assessment:         {quality}")
            report.append(f"   Samples analyzed:   {len(correction):,}")
            report.append(f"")
            report.append(f"   CORRECTION VALUE STATISTICS:")
            report.append(f"   Mean correction:    {correction_stats['mean']:+.4f}")
            report.append(f"   Std deviation:      {correction_stats['stdev']:.4f}")
            report.append(f"   Interquartile Range:{correction_stats['iqr']:.4f} ← primary stability metric")
            report.append(f"   Min / Max:          {correction_stats['min']:+.4f} / {correction_stats['max']:+.4f}")
            report.append(f"   Total range:        {correction_stats['range']:.4f}")
            report.append(f"")
            report.append(f"   INTERPRETATION:")
            
            if abs_mean_correction > 0.015:
                if correction_stats['mean'] > 0:
                    report.append(f"   • Positive mean correction: Buffer tends to need filling")
                    report.append(f"   • Possible causes: Receiver clock slightly faster than sender")
                else:
                    report.append(f"   • Negative mean correction: Buffer tends to need draining")
                    report.append(f"   • Possible causes: Receiver clock slightly slower than sender")
            else:
                report.append(f"   • Mean correction near zero: Well-balanced clocks")
            
            if correction_stats['iqr'] < 0.005:
                report.append(f"   • Low IQR: Very stable - minimal active correction needed")
                report.append(f"   • This suggests: Excellent clock matching OR effective PTP sync")
            elif correction_stats['iqr'] > 0.020:
                report.append(f"   • High IQR: Unstable - frequent buffer adjustments")
                report.append(f"   • This suggests: Clock drift present, Diretta is actively compensating")
                report.append(f"   • Recommendation: Consider enabling PTP synchronization")
            
            # Also analyze buffer difference and moving average
            if buffer_diff:
                diff_stats = self.analyze_stability(buffer_diff, "Buffer Difference")
                report.append(f"")
                report.append(f"   BUFFER DIFFERENCE FROM TARGET:")
                report.append(f"   Mean:               {diff_stats['mean']:+.4f}")
                report.append(f"   Std deviation:      {diff_stats['stdev']:.4f}")
                report.append(f"   Range:              {diff_stats['range']:.4f}")
            
#            report.append("-" * 100)
        else:
            report.append(f"2. BUFFER STABILITY: Insufficient data (need ≥10 samples, found {len(correction) if correction else 0})")
        
        report.append("\n" + "=" * 100)
        
        
        return "\n".join(report)

    def parse_diretta_logs(self, logs: str) -> dict:
        """
        Parse Diretta log format:
        info rcv 2 -0.0110 -0.0110  0.0019 cy=3185960450
                   ^^^^^^  ^^^^^^  ^^^^^^     ^^^^^^^^^^
                   diff    avg     correct    cycle_ps
        
        Where:
        - calc type: debugging calc type (ignored)
        - diff: Difference from target buffer level
        - avg: Moving average of the difference
        - correct: Correction value being applied
        - cy: Cycle time in picoseconds
        """
        pattern = r'info\s+rcv\s+\d+\s+([+-]?\d+\.\d+)\s+([+-]?\d+\.\d+)\s+([+-]?\d+\.\d+)\s+cy=(\d+)'
        
        buffer_diff = []
        buffer_avg = []
        correction = []
        cycle_times = []
        
        for match in re.finditer(pattern, logs):
            try:
                diff = float(match.group(1))
                avg = float(match.group(2))
                corr = float(match.group(3))
                cy_ps = float(match.group(4))
                
                buffer_diff.append(diff)
                buffer_avg.append(avg)
                correction.append(corr)
                cycle_times.append(cy_ps / 1_000_000)  # Convert ps to μs
            except (ValueError, IndexError):
                continue
        
        return {
            'buffer_diff': buffer_diff,
            'buffer_avg': buffer_avg,
            'correction': correction,
            'cycle_times': cycle_times
        }

    def _detect_cycle_time(self) -> float:
        """Try to detect cycle time from Diretta config file"""
        config_paths = [
            Path.home() / "DirettaAlsaHost" / "setting.inf",
            Path("/etc/diretta/setting.inf"),
        ]
        
        for config_path in config_paths:
            if config_path.exists():
                try:
                    with open(config_path, 'r') as f:
                        content = f.read()
                        match = re.search(r'CycleTime\s*=\s*(\d+)', content)
                        if match:
                            return float(match.group(1))
                except Exception:
                    pass
        
        return None

    def analyze_stability(self, values: list, data_type: str) -> dict:
        """Analyzes a list of numbers for stability, including IQR."""
        count = len(values)
        if count < 2:
            return {
                'count': count, 'mean': 0, 'stdev': 0, 
                'min': 0, 'max': 0, 'range': 0, 
                'q1': 0, 'q3': 0, 'iqr': 0
            }

        mean = np.mean(values)
        stdev = np.std(values)
        min_val = np.min(values)
        max_val = np.max(values)
        
        # Calculate Interquartile Range (IQR) to ignore outliers
        q1 = np.percentile(values, 25)
        q3 = np.percentile(values, 75)
        iqr = q3 - q1

        return {
            'count': count,
            'mean': mean,
            'stdev': stdev,
            'min': min_val,
            'max': max_val,
            'range': max_val - min_val,
            'q1': q1,
            'q3': q3,
            'iqr': iqr
        }


def validate_settings(period_min: int, period_max: int, 
                     period_size_min: int, period_size_max: int,
                     sync_buffer: int):
    """Validate settings and return warnings"""
    warnings = []
    
    ratio = period_max / period_min
    if ratio > 3:
        warnings.append(f"⚠ Large periodMin/Max ratio ({period_min}:{period_max} = {ratio:.1f}:1) "
                       f"may cause inefficient buffering. Recommended: ≤2.5:1")
    
    if sync_buffer < period_min:
        warnings.append(f"⚠ syncBufferCount ({sync_buffer}) < periodMin ({period_min}) "
                       f"may cause sync issues. Recommended: syncBuffer ≥ periodMin")
    
    if sync_buffer > period_max * 1.5:
        warnings.append(f"ℹ syncBufferCount ({sync_buffer}) >> periodMax ({period_max}) "
                       f"adds extra latency. Consider reducing if stability is good.")
    
    if period_size_min == period_size_max:
        warnings.append(f"ℹ periodSizeMin = periodSizeMax ({period_size_min}) "
                       f"forces fixed ALSA buffer. Usually auto-selection works better.")
    
    if period_size_min > 4096:
        warnings.append(f"⚠ periodSizeMin ({period_size_min}) is high. "
                       f"May cause compatibility issues with some applications.")
    
    if period_size_max < 2048:
        warnings.append(f"⚠ periodSizeMax ({period_size_max}) is low. "
                       f"May limit buffer flexibility.")
    
    total_periods = period_max + sync_buffer
    if total_periods < 10:
        warnings.append(f"⚠ Total buffering ({total_periods} periods) is aggressive. "
                       f"Monitor closely for underruns on loaded systems.")
    elif total_periods > 20:
        warnings.append(f"ℹ Total buffering ({total_periods} periods) is very conservative. "
                       f"Higher latency (~{total_periods * 3:.0f}ms) but maximum stability.")
    
    if period_min == 4 and period_max == 8 and sync_buffer == 6:
        warnings.append(f"✓ Using recommended optimized settings (4/8/6)")
    
    return warnings


def generate_config(cycle_time: int, period_min: int = 4, period_max: int = 8,
                   period_size_min: int = 2048, period_size_max: int = 8192,
                   sync_buffer: int = 6, latency_buffer: int = 0,
                   thred_mode: int = 257, interface: str = 'enp5s0',
                   cpu_send: int = 1, cpu_other: int = 2) -> str:
    """Generate Diretta configuration file content"""
    
    # CycleMinTime is 0.5% less than CycleTime
    cycle_min = int(cycle_time * 0.995)
    
    config = f"""[global]
Interface={interface}
TargetProfileLimitTime=0
ThredMode={thred_mode}
InfoCycle=100000
FlexCycle=max
CycleTime={cycle_time}
CycleMinTime={cycle_min}
Debug=stdout
periodMax={period_max}
periodMin={period_min}
periodSizeMax={period_size_max}
periodSizeMin={period_size_min}
syncBufferCount={sync_buffer}
alsaUnderrun=enable
unInitMemDet=disable
CpuSend={cpu_send}
CpuOther={cpu_other}
LatencyBuffer={latency_buffer}
"""
    return config


def print_header():
    """Print program header"""
    print("""
╔═══════════════════════════════════════════════════════════════════════════════╗
║              DIRETTA DDS CONFIGURATION & LOG ANALYSIS                         ║
║                    Optimized for High-Quality Reference Clocks                ║
║                          (e.g., Mutec REF10 SE120)                            ║
║                                                                               ║
║  Focus: Clock STABILITY (phase noise/jitter), not just accuracy               ║
╚═══════════════════════════════════════════════════════════════════════════════╝
""")


def main():
    parser = argparse.ArgumentParser(
        description='Diretta DDS Configuration Calculator with Log Analysis',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s                                      # Auto-detect MTU and generate config
  %(prog)s --detect-mtu                         # Show detected MTU for all interfaces
  %(prog)s --interface enp5s0                   # Use specific interface
  %(prog)s --analyze-memory                     # Analyze last 1,000 log entries
  %(prog)s --analyze-memory 10000               # Analyze last 10,000 log entries
  %(prog)s --config-only                        # Just show the config file text

""")
    
    # MTU Detection
    mtu_group = parser.add_argument_group('MTU Detection')
    mtu_group.add_argument('--detect-mtu', action='store_true',
                          help='Detect and display MTU settings for all network interfaces')
    mtu_group.add_argument('--interface', type=str, default=None,
                          help='Specify network interface (default: auto-detect highest MTU)')
    
    # Configuration Parameters
    calc_group = parser.add_argument_group('DDS Configuration')
    calc_group.add_argument('--mtu', type=int, default=None, 
                           help='MTU size in bytes (default: auto-detect from interface)')
    calc_group.add_argument('--pcm', action='store_true', help='Calculate for PCM instead of DSD')
    calc_group.add_argument('--period-min', type=int, default=4, help='periodMin: minimum network buffer depth (default: 4)')
    calc_group.add_argument('--period-max', type=int, default=8, help='periodMax: maximum network buffer depth (default: 8)')
    calc_group.add_argument('--sync-buffer', type=int, default=6, help='syncBufferCount: clock sync buffer (default: 6)')
    calc_group.add_argument('--latency-buffer', type=int, default=0, help='LatencyBuffer: additional latency (default: 0)')
    calc_group.add_argument('--period-size-min', type=int, default=2048, help='periodSizeMin: ALSA buffer minimum (default: 2048)')
    calc_group.add_argument('--period-size-max', type=int, default=8192, help='periodSizeMax: ALSA buffer maximum (default: 8192)')
    calc_group.add_argument('--thred-mode', type=int, default=257, help='ThredMode value (default: 257)')
    calc_group.add_argument('--cpu-send', type=int, default=1, help='CPU core for send thread (default: 1)')
    calc_group.add_argument('--cpu-other', type=int, default=2, help='CPU core for other threads (default: 2)')

    # Analysis Parameters
    analysis_group = parser.add_argument_group('Log Analysis')
    analysis_group.add_argument('--analyze-sync', type=int, nargs='?', const=1000, default=None, metavar='N',
                               help='Analyze the last N log entries from diretta_memoryplay_host service (default: 1000)')
    analysis_group.add_argument('--analyze-memory', type=int, nargs='?', const=1000, default=None, metavar='N',
                               help='Analyze the last N log entries from diretta_memoryplay_host service (default: 1000)')
    analysis_group.add_argument('--cycle-time', type=float, default=None,
                               help='Expected cycle time in microseconds (auto-detected from logs if not specified)')
      
    # Output Control
    output_group = parser.add_argument_group('Output Control')
    output_group.add_argument('--config-only', action='store_true',
                       help='Only generate and show the config file text')

    args = parser.parse_args()
    
    # MTU Detection Mode
    if args.detect_mtu:
        print_header()
        print(f"\n{'='*100}\nNETWORK INTERFACE MTU DETECTION\n{'='*100}\n")
        
        mtu_info = detect_network_mtu(args.interface)
        
        if mtu_info['mtu']:
            if args.interface:
                print(f"Interface: {mtu_info['interface']}")
                print(f"MTU: {mtu_info['mtu']} bytes")
                print(f"Detection method: {mtu_info['method']}")
            else:
                print("All network interfaces (excluding loopback):")
                for iface, mtu in sorted(mtu_info['all_interfaces'].items()):
                    marker = " ← AUTO-SELECTED (highest MTU)" if iface == mtu_info['interface'] else ""
                    print(f"  {iface:15s}: {mtu:5d} bytes{marker}")
                print(f"\nAuto-selected interface: {mtu_info['interface']} (MTU: {mtu_info['mtu']} bytes)")
                print(f"Detection method: {mtu_info['method']}")
        else:
            print(f"✗ Could not detect MTU")
            if args.interface:
                print(f"  Interface '{args.interface}' not found or MTU detection failed")
            else:
                print(f"  No network interfaces found or MTU detection failed")
        
        print(f"\n{'='*100}")
        return
    
    # Analysis Mode - Sync
    if args.analyze_sync is not None:
        monitor = DirettaMonitor(service_name="diretta_sync_host", cycle_time_us=args.cycle_time)
        report = monitor.analyze_recent_logs(num_lines=args.analyze_sync)
        print(report)
        return

    # Analysis Mode - Memory
    if args.analyze_memory is not None:
        monitor = DirettaMonitor(service_name="diretta_memoryplay_host", cycle_time_us=args.cycle_time)
        report = monitor.analyze_recent_logs(num_lines=args.analyze_memory)
        print(report)
        return

    # Configuration Mode - detect MTU if not specified
    if args.mtu is None:
        mtu_info = detect_network_mtu(args.interface)
        if mtu_info['mtu']:
            detected_mtu = mtu_info['mtu']
            detected_interface = mtu_info['interface']
            print(f"✓ Auto-detected MTU: {detected_mtu} bytes on interface {detected_interface}")
            # Override interface if auto-detected and not manually specified
            if args.interface is None:
                args.interface = detected_interface
        else:
            detected_mtu = 9024  # fallback default
            detected_interface = args.interface or 'enp5s0'
            print(f"⚠ MTU auto-detection failed, using default: {detected_mtu} bytes")
            if args.interface is None:
                args.interface = detected_interface
    else:
        detected_mtu = args.mtu
        detected_interface = args.interface or 'enp5s0'
    
    calculator = DirettaCalculator(mtu=detected_mtu)
    is_dsd = not args.pcm
    format_type = "DSD" if is_dsd else "PCM"
    
    # Calculate cycle time based on 48kHz
    target_cycle_us, params_48k = calculator.calculate_cycle_time_for_48k(is_dsd)
    
    # Calculate CycleMinTime (0.5% less than CycleTime)
    cycle_min_us = int(target_cycle_us * 0.995)
    
    warnings = validate_settings(args.period_min, args.period_max,
        args.period_size_min, args.period_size_max, args.sync_buffer)
    
    if not args.config_only:
        print_header()
        print(f"\n{'='*100}\nCONFIGURATION SUMMARY\n{'='*100}")
        print(f"Format: {format_type}")
        print(f"Interface: {detected_interface}")
        print(f"MTU: {detected_mtu} bytes")
        print(f"Base calculation: 48kHz (DSD256: {params_48k['sample_rate']:,} Hz)" if is_dsd else f"Base calculation: 48kHz (PCM: {params_48k['sample_rate']:,} Hz)")
        print(f"Samples per frame: {params_48k['samples_per_frame']:,}")
        print(f"Target CycleTime: {target_cycle_us} μs (optimized for 48kHz)")
        print(f"CycleMinTime: {cycle_min_us} μs (0.5% lower margin)")
        print(f"Network Buffering: periodMin={args.period_min}, periodMax={args.period_max}")
        print(f"Clock Sync Buffer: syncBufferCount={args.sync_buffer}")
        print(f"Total buffering: {args.period_max + args.sync_buffer} periods")
        if warnings:
            print(f"\n{'='*100}\nCONFIGURATION NOTES\n{'='*100}\n")
            for warning in warnings: 
                print(f"  {warning}\n")

    config = generate_config(cycle_time=target_cycle_us, period_min=args.period_min,
        period_max=args.period_max, period_size_min=args.period_size_min,
        period_size_max=args.period_size_max, sync_buffer=args.sync_buffer,
        latency_buffer=args.latency_buffer, thred_mode=args.thred_mode, interface=detected_interface,
        cpu_send=args.cpu_send, cpu_other=args.cpu_other)
    
    print(f"\n{'='*100}\nDIRETTA CONFIGURATION FILE\n{'='*100}\n")
    print(config)
    
    if not args.config_only:
        print(f"\n{'='*100}\nNEXT STEPS\n{'='*100}")
        print(f"""

1. SAVE CONFIGURATION:
   Copy the above to: ~/DirettaAlsaHost/setting.inf  || for diretta_sync_host service
   Copy the above to: ~/MemoryPlay/memoryplay_setting.inf  || for diretta_sync_host service

2. RESTART DIRETTA:
   sudo systemctl restart diretta_sync_host.service  || for diretta_sync_host service
   sudo systemctl restart diretta_memoryplay_host.service || for diretta_memoryplay_host service

3. ANALYZE PERFORMANCE:
   python3 {__file__} --analyze-sync 10000  || for diretta_sync_host service
   python3 {__file__} --analyze-memory 10000 || for diretta_memoryplay_host service
   
4. INTERPRET RESULTS:
   • Network jitter IQR < 0.5%: Excellent network stability
   • Buffer correction IQR < 0.010: Good clock matching
   • Buffer correction IQR > 0.020: Consider PTP synchronization
""")


if __name__ == "__main__":
    main()
