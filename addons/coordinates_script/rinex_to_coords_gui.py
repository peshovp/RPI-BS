#!/usr/bin/env python3
"""
RINEX .obs + Bulgaria GGF -> WGS84 (geocentric & geographic), ortometric height (using GGF), and BGS2005 (UTM 35N)
GUI application (Tkinter)

Requirements:
    pip install pyproj

Usage:
    python rinex_to_coords_gui.py

Features:
- Load a RINEX observation file (.obs, .o)
- Load a Bulgaria geoid file (GGF, Trimble grid)
- Parse APPROX POSITION XYZ from RINEX header
- Convert XYZ -> lat, lon, h_ell (WGS84)
- Interpolate geoid undulation from GGF (bilinear) -> N
- Compute H = h_ell - N
- Transform geographic -> BGS2005 / UTM zone 35N (EPSG:9391)
- Display results and save CSV

Note: This tool uses the APPROX POSITION XYZ stored in the RINEX header. For a true PPP Static solution you must process the raw observations with a PPP engine (CSRS-PPP, RTKLIB etc.). This script reproduces the same computations performed in the assistant's demo.
"""

import struct
import math
import tkinter as tk
from tkinter import filedialog, messagebox
from pyproj import Transformer
import csv
import traceback

# ---------------------- Core processing functions ----------------------

def parse_rinex_header(obs_path):
    """Read RINEX header and extract APPROX POSITION XYZ (returns tuple X,Y,Z in meters).
    Raises ValueError if not found."""
    with open(obs_path, 'r', errors='replace') as f:
        for line in f:
            if 'END OF HEADER' in line:
                break
            if 'APPROX POSITION XYZ' in line.upper():
                # numeric fields are usually in columns 0..60, split and extract floats
                part = line[:60].strip()
                parts = part.split()
                nums = []
                for p in parts:
                    try:
                        nums.append(float(p))
                    except:
                        pass
                if len(nums) >= 3:
                    return (nums[0], nums[1], nums[2])
    raise ValueError('APPROX POSITION XYZ not found in RINEX header')


def xyz_to_geodetic(X, Y, Z):
    """Convert geocentric WGS84 X,Y,Z (m) to geodetic lat, lon (deg) and ellipsoidal height h (m).
    Uses iterative method (Bowring-like)."""
    # WGS84
    a = 6378137.0
    f = 1.0 / 298.257223563
    e2 = 2*f - f*f

    lon = math.degrees(math.atan2(Y, X))
    p = math.hypot(X, Y)
    lat = math.atan2(Z, p*(1 - e2))
    for _ in range(20):
        N = a / math.sqrt(1 - e2 * math.sin(lat)**2)
        h = p / math.cos(lat) - N
        lat_new = math.atan2(Z, p * (1 - e2 * (N/(N+h))))
        if abs(lat_new - lat) < 1e-12:
            lat = lat_new
            break
        lat = lat_new
    N = a / math.sqrt(1 - e2 * math.sin(lat)**2)
    h = p / math.cos(lat) - N
    return (math.degrees(lat), lon, h)


# GGF parsing based on common Trimble GGF layout (header with doubles and grid of float32 LE)
def read_ggf(ggf_path):
    """Parse a Trimble GGF geoid file. Returns dict with xmin,xmax,ymin,ymax,dx,dy,vNX,vNY,grid (list of rows south->north, each row west->east)
    Raises ValueError on failure."""
    with open(ggf_path, 'rb') as f:
        data = f.read()

    # Helper to unpack little-endian values
    def ld(off):
        return struct.unpack_from('<d', data, off)[0]
    def lu(off):
        return struct.unpack_from('<I', data, off)[0]

    # Common offsets found in many GGF files
    # Note: some GGF variants include small differences; we attempt to read expected header fields and then locate float grid
    try:
        ymin = ld(0x30)
        ymax = ld(0x38)
        xmin = ld(0x40)
        xmax = ld(0x48)
        dy = ld(0x50)
        dx = ld(0x58)
        vNY = lu(0x60)
        vNX = lu(0x64)
    except Exception as e:
        raise ValueError('Unexpected GGF header layout or corrupted file: %s' % e)

    # expected number of float32 values
    expected = int(vNX) * int(vNY)

    # typical data start offset (may vary); try default 0x92 and fallback search
    candidates = [0x92, 0x80, 0x70, 0xA0]
    grid_floats = None
    for start in candidates:
        if start >= len(data):
            continue
        bytes_av = len(data) - start
        count = bytes_av // 4
        if count >= expected:
            try:
                fmt = '<' + ('f' * expected)
                floats = struct.unpack_from(fmt, data, start)
                grid_floats = floats
                data_start = start
                break
            except Exception:
                pass

    if grid_floats is None:
        # try scanning for a plausible start by testing several offsets
        found = False
        for start in range(0x40, 0x200, 2):
            if start >= len(data):
                break
            bytes_av = len(data) - start
            count = bytes_av // 4
            if count >= expected:
                try:
                    fmt = '<' + ('f' * expected)
                    floats = struct.unpack_from(fmt, data, start)
                    grid_floats = floats
                    data_start = start
                    found = True
                    break
                except Exception:
                    continue
        if not found:
            raise ValueError('Could not locate float grid in GGF file')

    # Build 2D grid: Trimble GGF stores rows south->north, each row west->east
    grid = []
    idx = 0
    for i in range(vNY):
        row = []
        for j in range(vNX):
            row.append(float(grid_floats[idx]))
            idx += 1
        grid.append(row)

    return {
        'ymin': ymin, 'ymax': ymax, 'xmin': xmin, 'xmax': xmax,
        'dy': dy, 'dx': dx, 'vNY': vNY, 'vNX': vNX,
        'grid': grid
    }


def interp_geoid_bilinear(ggf_info, lat, lon):
    """Interpolate geoid undulation N (meters) at given lat, lon (degrees) using bilinear interpolation.
    Raises ValueError if point outside grid."""
    ymin = ggf_info['ymin']; ymax = ggf_info['ymax']
    xmin = ggf_info['xmin']; xmax = ggf_info['xmax']
    dy = ggf_info['dy']; dx = ggf_info['dx']
    vNY = ggf_info['vNY']; vNX = ggf_info['vNX']

    lon_adj = lon
    # handle 0..360 vs -180..180
    if xmin >= 0 and lon < 0:
        lon_adj = lon + 360

    row_f = (lat - ymin) / dy
    col_f = (lon_adj - xmin) / dx

    if not (0 <= row_f <= vNY - 1 and 0 <= col_f <= vNX - 1):
        raise ValueError('Point (lat,lon) outside GGF grid bounds')

    i = int(math.floor(row_f))
    j = int(math.floor(col_f))
    fi = row_f - i
    fj = col_f - j

    v00 = ggf_info['grid'][i][j]
    v01 = ggf_info['grid'][i][j+1] if j+1 < vNX else v00
    v10 = ggf_info['grid'][i+1][j] if i+1 < vNY else v00
    v11 = ggf_info['grid'][i+1][j+1] if (i+1 < vNY and j+1 < vNX) else v00

    val = (v00*(1-fi)*(1-fj) + v01*(1-fi)*fj + v10*fi*(1-fj) + v11*fi*fj)
    return float(val)

# ---------------------- GUI ----------------------

class App:
    def __init__(self, root):
        self.root = root
        root.title('RINEX -> Coordinates (WGS84, Ortho, BGS2005)')
        self.rinex_path = None
        self.ggf_path = None
        self.ggf_info = None
        self.approx_xyz = None

        frame = tk.Frame(root, padx=10, pady=10)
        frame.pack(fill='both', expand=True)

        row = 0
        tk.Button(frame, text='Load RINEX (.obs)', command=self.load_rinex).grid(row=row, column=0, sticky='w')
        self.rinex_label = tk.Label(frame, text='(no file)')
        self.rinex_label.grid(row=row, column=1, sticky='w')
        row += 1

        tk.Button(frame, text='Load GGF (geoid)', command=self.load_ggf).grid(row=row, column=0, sticky='w')
        self.ggf_label = tk.Label(frame, text='(no file)')
        self.ggf_label.grid(row=row, column=1, sticky='w')
        row += 1

        tk.Button(frame, text='Compute', command=self.compute).grid(row=row, column=0, pady=(8,4))
        tk.Button(frame, text='Save CSV', command=self.save_csv).grid(row=row, column=1, pady=(8,4))
        row += 1

        # Results area
        self.txt = tk.Text(frame, width=80, height=12)
        self.txt.grid(row=row, column=0, columnspan=2, pady=(6,0))

    def load_rinex(self):
        p = filedialog.askopenfilename(title='Open RINEX observation file', filetypes=[('RINEX', '*.obs *.o *.19o *.20o *.21o *.22o *.23o *.24o'), ('All files','*.*')])
        if not p:
            return
        try:
            self.approx_xyz = parse_rinex_header(p)
            self.rinex_path = p
            self.rinex_label.config(text=p)
            messagebox.showinfo('RINEX loaded', 'APPROX POSITION XYZ found: X=%.3f Y=%.3f Z=%.3f' % self.approx_xyz)
        except Exception as e:
            messagebox.showerror('Error parsing RINEX', str(e))
            traceback.print_exc()

    def load_ggf(self):
        p = filedialog.askopenfilename(title='Open GGF geoid file', filetypes=[('GGF', '*.GGF *.ggf'), ('All files','*.*')])
        if not p:
            return
        try:
            self.ggf_info = read_ggf(p)
            self.ggf_path = p
            self.ggf_label.config(text=p)
            messagebox.showinfo('GGF loaded', 'GGF loaded: bounds lat %.6f..%.6f lon %.6f..%.6f grid %dx%d' % (
                self.ggf_info['ymin'], self.ggf_info['ymax'], self.ggf_info['xmin'], self.ggf_info['xmax'], self.ggf_info['vNY'], self.ggf_info['vNX']))
        except Exception as e:
            messagebox.showerror('Error parsing GGF', str(e))
            traceback.print_exc()

    def compute(self):
        self.txt.delete('1.0', tk.END)
        if not self.approx_xyz:
            messagebox.showwarning('Missing RINEX', 'Load a RINEX .obs file first')
            return
        X, Y, Z = self.approx_xyz
        try:
            lat, lon, h_ell = xyz_to_geodetic(X, Y, Z)
        except Exception as e:
            messagebox.showerror('Conversion error', 'Failed to convert XYZ->lat/lon: %s' % e)
            return

        N = None
        H = None
        if self.ggf_info is not None:
            try:
                N = interp_geoid_bilinear(self.ggf_info, lat, lon)
                H = h_ell - N
            except Exception as e:
                messagebox.showwarning('Geoid warning', 'Could not interpolate N from GGF: %s' % e)

        # Transform to BGS2005 / UTM zone 35N (EPSG:9391)
        try:
            t = Transformer.from_crs('EPSG:4326', 'EPSG:9391', always_xy=True)
            easting, northing = t.transform(lon, lat)
        except Exception as e:
            easting = northing = None

        # Display
        lines = []
        lines.append('Geocentric (WGS84) X (m): %.3f' % X)
        lines.append('Geocentric (WGS84) Y (m): %.3f' % Y)
        lines.append('Geocentric (WGS84) Z (m): %.3f' % Z)
        lines.append('')
        lines.append('Geographic (WGS84):')
        lines.append('  Latitude (deg): %.12f' % lat)
        lines.append('  Longitude (deg): %.12f' % lon)
        lines.append('  Ellipsoidal height h (m): %.6f' % h_ell)
        lines.append('')
        if N is not None:
            lines.append('Geoid undulation N from GGF (m): %.6f' % N)
            lines.append('Orthometric height H = h - N (m): %.6f' % H)
        else:
            lines.append('Geoid undulation: (GGF not loaded or interpolation failed)')
        lines.append('')
        if easting is not None:
            lines.append('BGS2005 / UTM (EPSG:9391):')
            lines.append('  Easting (m): %.3f' % easting)
            lines.append('  Northing (m): %.3f' % northing)
            if H is not None:
                lines.append('  Orthometric height H (m): %.6f' % H)
        else:
            lines.append('BGS2005 transform failed (pyproj)')

        self.txt.insert('1.0', '\n'.join(lines))
        # store last result for saving
        self.last_result = {
            'X': X, 'Y': Y, 'Z': Z,
            'lat': lat, 'lon': lon, 'h_ell': h_ell,
            'N': N, 'H': H,
            'easting': easting, 'northing': northing
        }

    def save_csv(self):
        if not hasattr(self, 'last_result'):
            messagebox.showwarning('No result', 'Run Compute first')
            return
        p = filedialog.asksaveasfilename(defaultextension='.csv', filetypes=[('CSV', '*.csv')])
        if not p:
            return
        try:
            r = self.last_result
            with open(p, 'w', newline='') as csvf:
                w = csv.writer(csvf)
                w.writerow(['frame','X_m','Y_m','Z_m','lat_deg','lon_deg','h_ell_m','N_m','H_m','easting_m','northing_m'])
                w.writerow(['WGS84_geocentric', '%.6f' % r['X'], '%.6f' % r['Y'], '%.6f' % r['Z'], '%.12f' % r['lat'], '%.12f' % r['lon'], '%.6f' % r['h_ell'], '%.6f' % (r['N'] if r['N'] is not None else float('nan')), '%.6f' % (r['H'] if r['H'] is not None else float('nan')), '%.3f' % (r['easting'] if r['easting'] is not None else float('nan')), '%.3f' % (r['northing'] if r['northing'] is not None else float('nan'))])
            messagebox.showinfo('Saved', 'CSV saved to: %s' % p)
        except Exception as e:
            messagebox.showerror('Save error', str(e))
            traceback.print_exc()


if __name__ == '__main__':
    root = tk.Tk()
    app = App(root)
    root.mainloop()
