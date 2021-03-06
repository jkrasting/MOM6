!> Interface to CVMix interior shear schemes
module MOM_CVMix_shear

! This file is part of MOM6. See LICENSE.md for the license.

!---------------------------------------------------
! module MOM_CVMix_shear
! Author: Brandon Reichl
! Date: Aug 31, 2016
! Purpose: Interface to CVMix interior shear schemes
! Further information to be added at a later time.
!---------------------------------------------------

use MOM_diag_mediator, only : post_data, register_diag_field, safe_alloc_ptr
use MOM_diag_mediator, only : diag_ctrl, time_type
use MOM_error_handler, only : MOM_error, is_root_pe, FATAL, WARNING, NOTE
use MOM_file_parser, only : get_param, log_version, param_file_type
use MOM_grid, only : ocean_grid_type
use MOM_variables, only : thermo_var_ptrs
use MOM_verticalGrid, only : verticalGrid_type
use MOM_EOS, only : calculate_density, EOS_type
use CVMix_shear, only : CVMix_init_shear, CVMix_coeffs_shear
use MOM_kappa_shear, only : kappa_shear_is_used
implicit none ; private

#include <MOM_memory.h>

public calculate_CVMix_shear, CVMix_shear_init, CVMix_shear_is_used, CVMix_shear_end

!> Control structure including parameters for CVMix interior shear schemes.
type, public :: CVMix_shear_cs
  logical :: use_LMD94, use_PP81            !< Flags for various schemes
  real    :: Ri_zero                        !< LMD94 critical Richardson number
  real    :: Nu_zero                        !< LMD94 maximum interior diffusivity
  real    :: KPP_exp                        !<
  real, allocatable, dimension(:,:,:) :: N2 !< Squared Brunt-Vaisala frequency (1/s2)
  real, allocatable, dimension(:,:,:) :: S2 !< Squared shear frequency (1/s2)
  real, allocatable, dimension(:,:,:) :: ri_grad !< Gradient Richardson number
!  real, allocatable, dimension(:,:,:) :: kv !< vertical viscosity at interface (m2/s)
!  real, allocatable, dimension(:,:,:) :: kd !< vertical diffusivity at interface (m2/s)
  character(10) :: Mix_Scheme               !< Mixing scheme name (string)
  ! Daignostic handles and pointers
  type(diag_ctrl), pointer :: diag => NULL()
  integer :: id_N2 = -1, id_S2 = -1, id_ri_grad = -1, id_kv = -1, id_kd = -1

end type CVMix_shear_cs

character(len=40)  :: mdl = "MOM_CVMix_shear"  !< This module's name.

contains

!> Subroutine for calculating (internal) vertical diffusivities/viscosities
subroutine calculate_CVMix_shear(u_H, v_H, h, tv, kd,  &
                                 kv, G, GV, CS )
  type(ocean_grid_type),                      intent(in)  :: G !< Grid structure.
  type(verticalGrid_type),                    intent(in)  :: GV !< Vertical grid structure.
  real, dimension(SZI_(G),SZJ_(G),SZK_(G)),   intent(in)  :: u_H !< Initial zonal velocity on T points, in m s-1.
  real, dimension(SZI_(G),SZJ_(G),SZK_(G)),   intent(in)  :: v_H !< Initial meridional velocity on T points, in m s-1.
  real, dimension(SZI_(G),SZJ_(G),SZK_(G)),   intent(in)  :: h !< Layer thickness, in m or kg m-2.
  type(thermo_var_ptrs),                      intent(in)  :: tv !< Thermodynamics structure.
  real, dimension(SZI_(G),SZJ_(G),SZK_(G)+1), intent(out) :: kd !< The vertical diffusivity at each interface
                                                                !! (not layer!) in m2 s-1.
  real, dimension(SZI_(G),SZJ_(G),SZK_(G)+1), intent(out) :: kv !< The vertical viscosity at each interface
                                                                !! (not layer!) in m2 s-1.
  type(CVMix_shear_cs),                       pointer     :: CS !< The control structure returned by a previous call to
                                                                !! CVMix_shear_init.
  ! Local variables
  integer :: i, j, k, kk, km1
  real :: gorho
  real :: pref, DU, DV, DRHO, DZ, N2, S2
  real, dimension(2*(G%ke)) :: pres_1d, temp_1d, salt_1d, rho_1d
  real, dimension(G%ke+1) ::  Ri_Grad !< Gradient Richardson number

  ! some constants
  GoRho = GV%g_Earth / GV%Rho0

  do j = G%jsc, G%jec
    do i = G%isc, G%iec

      ! skip calling for land points
      if (G%mask2dT(i,j)==0.) cycle

      ! Richardson number computed for each cell in a column.
      pRef = 0.
      Ri_Grad(:)=1.e8 !Initialize w/ large Richardson value
      do k=1,G%ke
        ! pressure, temp, and saln for EOS
        ! kk+1 = k fields
        ! kk+2 = km1 fields
        km1  = max(1, k-1)
        kk   = 2*(k-1)
        pres_1D(kk+1) = pRef
        pres_1D(kk+2) = pRef
        Temp_1D(kk+1) = TV%T(i,j,k)
        Temp_1D(kk+2) = TV%T(i,j,km1)
        Salt_1D(kk+1) = TV%S(i,j,k)
        Salt_1D(kk+2) = TV%S(i,j,km1)

        ! pRef is pressure at interface between k and km1.
        ! iterate pRef for next pass through k-loop.
        pRef = pRef + GV%H_to_Pa * h(i,j,k)

      enddo ! k-loop finishes

      ! compute in-situ density
      call calculate_density(Temp_1D, Salt_1D, pres_1D, rho_1D, 1, 2*G%ke, TV%EQN_OF_STATE)

      ! N2 (can be negative) on interface
      do k = 1, G%ke
        km1 = max(1, k-1)
        kk = 2*(k-1)
        DU = (u_h(i,j,k))-(u_h(i,j,km1))
        DV = (v_h(i,j,k))-(v_h(i,j,km1))
        DRHO = (GoRho * (rho_1D(kk+1) - rho_1D(kk+2)) )
        DZ = ((0.5*(h(i,j,km1) + h(i,j,k))+GV%H_subroundoff)*GV%H_to_m)
        N2 = DRHO/DZ
        S2 = (DU*DU+DV*DV)/(DZ*DZ)
        Ri_Grad(k) = max(0.,N2)/max(S2,1.e-16)

        ! fill 3d arrays, if user asks for diagsnostics
        if (CS%id_N2 > 0) CS%N2(i,j,k) = N2
        if (CS%id_S2 > 0) CS%S2(i,j,k) = S2
        if (CS%id_ri_grad > 0) CS%ri_grad(i,j,k) = Ri_Grad(k)

      enddo

      ! Call to CVMix wrapper for computing interior mixing coefficients.
      call  CVMix_coeffs_shear(Mdiff_out=kv(i,j,:), &
                                   Tdiff_out=kd(i,j,:), &
                                   RICH=Ri_Grad, &
                                   nlev=G%ke,    &
                                   max_nlev=G%ke)
    enddo
  enddo

  ! write diagnostics
  if (CS%id_kd > 0) call post_data(CS%id_kd,kd, CS%diag)
  if (CS%id_kv > 0) call post_data(CS%id_kv,kv, CS%diag)
  if (CS%id_N2 > 0) call post_data(CS%id_N2,CS%N2, CS%diag)
  if (CS%id_S2 > 0) call post_data(CS%id_S2,CS%S2, CS%diag)
  if (CS%id_ri_grad > 0) call post_data(CS%id_ri_grad,CS%ri_grad, CS%diag)

end subroutine calculate_CVMix_shear


!> Initialized the CVMix internal shear mixing routine.
!! \note *This is where we test to make sure multiple internal shear
!!       mixing routines (including JHL) are not enabled at the same time.
!! (returns) CVMix_shear_init - True if module is to be used, False otherwise
logical function CVMix_shear_init(Time, G, GV, param_file, diag, CS)
  type(time_type),         intent(in)    :: Time !< The current time.
  type(ocean_grid_type),   intent(in)    :: G !< Grid structure.
  type(verticalGrid_type), intent(in)    :: GV !< Vertical grid structure.
  type(param_file_type),   intent(in)    :: param_file !< Run-time parameter file handle
  type(diag_ctrl), target, intent(inout) :: diag !< Diagnostics control structure.
  type(CVMix_shear_cs),    pointer       :: CS !< This module's control structure.
  ! Local variables
  integer :: NumberTrue=0
  logical :: use_JHL
! This include declares and sets the variable "version".
#include "version_variable.h"

  if (associated(CS)) then
    call MOM_error(WARNING, "CVMix_shear_init called with an associated "// &
                            "control structure.")
    return
  endif
  allocate(CS)

! Set default, read and log parameters
  call log_version(param_file, mdl, version, &
    "Parameterization of shear-driven turbulence via CVMix (various options)")
  call get_param(param_file, mdl, "USE_LMD94", CS%use_LMD94, &
                 "If true, use the Large-McWilliams-Doney (JGR 1994) \n"//&
                 "shear mixing parameterization.", default=.false.)
  if (CS%use_LMD94) then
     NumberTrue=NumberTrue + 1
     CS%Mix_Scheme='KPP'
  endif
  call get_param(param_file, mdl, "USE_PP81", CS%use_PP81, &
                 "If true, use the Pacanowski and Philander (JPO 1981) \n"//&
                 "shear mixing parameterization.", default=.false.)
  if (CS%use_PP81) then
     NumberTrue = NumberTrue + 1
     CS%Mix_Scheme='PP'
  endif
  use_JHL=kappa_shear_is_used(param_file)
  if (use_JHL) NumberTrue = NumberTrue + 1
  ! After testing for interior schemes, make sure only 0 or 1 are enabled.
  ! Otherwise, warn user and kill job.
  if ((NumberTrue).gt.1) then
     call MOM_error(FATAL, 'MOM_CVMix_shear_init: '// &
           'Multiple shear driven internal mixing schemes selected,'//&
           ' please disable all but one scheme to proceed.')
  endif
  CVMix_shear_init=(CS%use_PP81.or.CS%use_LMD94)

! Forego remainder of initialization if not using this scheme
  if (.not. CVMix_shear_init) return
  call get_param(param_file, mdl, "NU_ZERO", CS%Nu_Zero, &
                 "Leading coefficient in KPP shear mixing.", &
                 units="nondim", default=5.e-3)
  call get_param(param_file, mdl, "RI_ZERO", CS%Ri_Zero, &
                 "Critical Richardson for KPP shear mixing,"// &
                 " NOTE this the internal mixing and this is"// &
                 " not for setting the boundary layer depth." &
                 ,units="nondim", default=0.7)
  call get_param(param_file, mdl, "KPP_EXP", CS%KPP_exp, &
                 "Exponent of unitless factor of diffusivities,"// &
                 " for KPP internal shear mixing scheme." &
                 ,units="nondim", default=3.0)
  call CVMix_init_shear(mix_scheme=CS%mix_scheme, &
                        KPP_nu_zero=CS%Nu_Zero,   &
                        KPP_Ri_zero=CS%Ri_zero,   &
                        KPP_exp=CS%KPP_exp)

  ! Register diagnostics; allocation and initialization
  CS%diag => diag

  CS%id_N2 = register_diag_field('ocean_model', 'N2_shear', diag%axesTi, Time, &
      'Square of Brunt-Vaisala frequency used by MOM_CVMix_shear module', '1/s2')
  if (CS%id_N2 > 0) &
    allocate( CS%N2( SZI_(G), SZJ_(G), SZK_(G)+1 ) );CS%N2(:,:,:) = 0.

  CS%id_S2 = register_diag_field('ocean_model', 'S2_shear', diag%axesTi, Time, &
      'Square of vertical shear used by MOM_CVMix_shear module','1/s2')
  if (CS%id_S2 > 0) &
    allocate( CS%S2( SZI_(G), SZJ_(G), SZK_(G)+1 ) );CS%S2(:,:,:) = 0.

  CS%id_ri_grad = register_diag_field('ocean_model', 'ri_grad_shear', diag%axesTi, Time, &
      'Gradient Richarson number used by MOM_CVMix_shear module','nondim')
  if (CS%id_ri_grad > 0) & !Initialize w/ large Richardson value
     allocate( CS%ri_grad( SZI_(G), SZJ_(G), SZK_(G)+1 ));CS%ri_grad(:,:,:) = 1.e8

  CS%id_kd = register_diag_field('ocean_model', 'kd_shear_CVMix', diag%axesTi, Time, &
      'Vertical diffusivity added by MOM_CVMix_shear module', 'm2/s')
  CS%id_kv = register_diag_field('ocean_model', 'kv_shear_CVMix', diag%axesTi, Time, &
      'Vertical viscosity added by MOM_CVMix_shear module', 'm2/s')

end function CVMix_shear_init

!> Reads the parameters "LMD94" and "PP81" and returns state.
!!   This function allows other modules to know whether this parameterization will
!! be used without needing to duplicate the log entry.
logical function CVMix_shear_is_used(param_file)
  type(param_file_type), intent(in) :: param_file !< Run-time parameter files handle.
  ! Local variables
  logical :: LMD94, PP81
  call get_param(param_file, mdl, "USE_LMD94", LMD94, &
       default=.false., do_not_log = .true.)
  call get_param(param_file, mdl, "Use_PP81", PP81, &
       default=.false., do_not_log = .true.)
  CVMix_shear_is_used = (LMD94 .or. PP81)
end function CVMix_shear_is_used

!> Clear pointers and dealocate memory
subroutine CVMix_shear_end(CS)
  type(CVMix_shear_cs), pointer :: CS ! Control structure

  if (CS%id_N2 > 0) deallocate(CS%N2)
  if (CS%id_S2 > 0) deallocate(CS%S2)
  if (CS%id_ri_grad > 0) deallocate(CS%ri_grad)
  deallocate(CS)

end subroutine CVMix_shear_end

end module MOM_CVMix_shear
