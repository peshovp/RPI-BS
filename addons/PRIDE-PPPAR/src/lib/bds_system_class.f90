!
!! bds_system_class.f90
!!
!!    Copyright (C) 2023 by Wuhan University
!!
!!    This program belongs to PRIDE PPP-AR which is an open source software:
!!    you can redistribute it and/or modify it under the terms of the GNU
!!    General Public License (version 3) as published by the Free Software Foundation.
!!
!!    This program is distributed in the hope that it will be useful,
!!    but WITHOUT ANY WARRANTY; without even the implied warranty of
!!    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
!!    GNU General Public License (version 3) for more details.
!!
!!    You should have received a copy of the GNU General Public License
!!    along with this program. If not, see <https://www.gnu.org/licenses/>.
!!
!! Contributor: Bingchen Fu
!!
!!
!!
!! purpose   : determine BDS system type (BDS2 or BDS3) based on PRN and date
!!             to adapt BDS reconfiguration on 2026-04-21
!! parameters:
!!             prn_int -- PRN number (integer, 1-63)
!!             jd      -- Modified Julian Day
!!             sod     -- second of day (0-86400)
!! return    : 2 for BDS2, 3 for BDS3
!!
!! rules     :
!!             Before 2026-04-21 (jd < 61151):
!!               PRN <= 18 -> BDS2
!!               PRN >= 19 -> BDS3
!!             After 2026-04-21 (jd >= 61151):
!!               All BDS satellites -> BDS3
!
integer*4 function bds_system_class(prn_int, jd, sod)
  implicit none

  integer*4, intent(in) :: prn_int, jd, sod

! BDS reconfiguration date: 2026-04-21 (Modified Julian Day)
  integer*4, parameter :: MJD_RECONFIG = 61151

  if (jd < MJD_RECONFIG) then
!   Before reconfiguration: PRN <= 18 -> BDS2, PRN >= 19 -> BDS3
    if (prn_int <= 18) then
      bds_system_class = 2
    else
      bds_system_class = 3
    end if
  else
!   After reconfiguration: All BDS satellites -> BDS3
    bds_system_class = 3
  end if

end function bds_system_class