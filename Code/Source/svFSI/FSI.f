!
! Copyright (c) Stanford University, The Regents of the University of
!               California, and others.
!
! All Rights Reserved.
!
! See Copyright-SimVascular.txt for additional details.
!
! Permission is hereby granted, free of charge, to any person obtaining
! a copy of this software and associated documentation files (the
! "Software"), to deal in the Software without restriction, including
! without limitation the rights to use, copy, modify, merge, publish,
! distribute, sublicense, and/or sell copies of the Software, and to
! permit persons to whom the Software is furnished to do so, subject
! to the following conditions:
!
! The above copyright notice and this permission notice shall be included
! in all copies or substantial portions of the Software.
!
! THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
! IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
! TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
! PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER
! OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
! EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
! PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
! PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
! LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
! NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
! SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
!
!--------------------------------------------------------------------
!
!     This is for constructing FSI equations on fluid and solid
!     domains.
!
!--------------------------------------------------------------------

      SUBROUTINE CONSTRUCT_FSI(lM, Ag, Yg, Dg)
      USE COMMOD
      USE ALLFUN
      IMPLICIT NONE
      TYPE(mshType), INTENT(IN) :: lM
      REAL(KIND=RKIND), INTENT(IN) :: Ag(tDof,tnNo), Yg(tDof,tnNo),
     2   Dg(tDof,tnNo)

      LOGICAL :: vmsStab
      INTEGER(KIND=IKIND) a, b, e, g, l, Ac, eNoN, cPhys, iFn, nFn
      REAL(KIND=RKIND) w, Jac, ksix(nsd,nsd)
      TYPE(fsType) :: fs(2)

      INTEGER(KIND=IKIND), ALLOCATABLE :: ptr(:)
      REAL(KIND=RKIND), ALLOCATABLE :: xl(:,:), al(:,:), yl(:,:),
     2   dl(:,:), bfl(:,:), fN(:,:), pS0l(:,:), pSl(:), tmXl(:),
     3   ya_l(:), lR(:,:), lK(:,:,:), lKd(:,:,:)
      REAL(KIND=RKIND), ALLOCATABLE :: xwl(:,:), xql(:,:), Nwx(:,:),
     2   Nwxx(:,:), Nqx(:,:)

      eNoN = lM%eNoN
      IF (lM%eType .EQ. eType_TRI3) eNoN = 2*eNoN
      nFn  = lM%nFn
      IF (nFn .EQ. 0) nFn = 1

      IF (lM%nFs .EQ. 1) THEN
         vmsStab = .TRUE.
      ELSE
         vmsStab = .FALSE.
      END IF

!     l = 3, if nsd==2 ; else 6;
      l = nsymd

      ALLOCATE(ptr(eNoN), xl(nsd,eNoN), al(tDof,eNoN), yl(tDof,eNoN),
     2   dl(tDof,eNoN), bfl(nsd,eNoN), fN(nsd,nFn), pS0l(nsymd,eNoN),
     3   pSl(nsymd), tmXl(eNoN), ya_l(eNoN), lR(dof,eNoN),
     4   lK(dof*dof,eNoN,eNoN), lKd(dof*nsd,eNoN,eNoN))

!     Loop over all elements of mesh
      DO e=1, lM%nEl
         cDmn  = DOMAIN(lM, cEq, e)
         cPhys = eq(cEq)%dmn(cDmn)%phys
         IF ((cPhys .NE. phys_fluid)  .AND.
     2       (cPhys .NE. phys_lElas)  .AND.
     3       (cPhys .NE. phys_struct) .AND.
     4       (cPhys .NE. phys_ustruct) .AND. 
     5       (cPhys .NE. phys_shell) ) CYCLE

!        Update shape functions for NURBS
         IF (lM%eType .EQ. eType_NRB) CALL NRBNNX(lM, e)

!        Create local copies
         fN   = 0._RKIND
         pS0l = 0._RKIND
         tmXl = 0._RKIND
         ya_l = 0._RKIND
         DO a=1, eNoN
            IF (a .LE. lM%eNoN) THEN
               Ac = lM%IEN(a,e)
               ptr(a) = Ac
            ELSE
               b  = a - lM%eNoN
               Ac = lM%eIEN(b,e)
               ptr(a) = Ac
               IF (Ac .EQ. 0) CYCLE
            END IF
            Ac = lM%IEN(a,e)
            ptr(a)   = Ac
            xl(:,a)  = x(:,Ac)
            al(:,a)  = Ag(:,Ac)
            yl(:,a)  = Yg(:,Ac)
            dl(:,a)  = Dg(:,Ac)
            bfl(:,a) = Bf(:,Ac)
            IF (ALLOCATED(pS0)) pS0l(:,a) = pS0(:,Ac)
            IF (ecCpld) THEN
               IF (ALLOCATED(lM%tmX)) THEN
                  tmXl(a) = lM%tmX(lM%lN(Ac))
               END IF
               IF (ALLOCATED(ec_Ya)) THEN
                  ya_l(a) = ec_Ya(Ac)
               ELSE
                  ya_l(a) = eq(cEq)%dmn(cDmn)%ec%Ya
               END IF
            END IF
         END DO

         IF (ALLOCATED(lM%fN)) THEN
            DO iFn=1, nFn
               fN(:,iFn) = lM%fN((iFn-1)*nsd+1:iFn*nsd,e)
            END DO
         END IF

!        For FSI, fluid domain should be in the current configuration
!        Add fluid mesh displacements to node points
         IF (cPhys .EQ. phys_fluid) THEN
            xl(:,:) = xl(:,:) + dl(nsd+2:2*nsd+1,:)
         END IF

!        Initialize residue and tangents
         lR  = 0._RKIND
         lK  = 0._RKIND
         lKd = 0._RKIND

!        Set function spaces for velocity and pressure.
         CALL GETTHOODFS(fs, lM, vmsStab, 1)

!        Define element coordinates appropriate for function spaces
         ALLOCATE(xwl(nsd,fs(1)%eNoN), Nwx(nsd,fs(1)%eNoN),
     2      Nwxx(l,fs(1)%eNoN))
         ALLOCATE(xql(nsd,fs(2)%eNoN), Nqx(nsd,fs(2)%eNoN))
         xwl(:,:) = xl(:,:)
         xql(:,:) = xl(:,1:fs(2)%eNoN)
         Nwx      = 0._RKIND
         Nqx      = 0._RKIND
         Nwxx     = 0._RKIND

         IF (lM%lShl) THEN
            IF (lM%eType .EQ. eType_TRI3) THEN
!              Constant strain triangles, no numerical integration
               CALL SHELLCST(fs(1), e, eNoN, nFn, fN, al, yl, dl, xl,
     2             bfl, ptr)
            ELSE
!              Gauss integration
               DO g=1, fs(1)%nG
                  CALL SHELL3D(fs(1), g, eNoN, nFn, fN, al, yl, dl, 
     2               xl, bfl, lR, lK)
               END DO
            END IF
         ELSE
!           Gauss integration 1
            DO g=1, fs(1)%nG
               IF (g.EQ.1 .OR. .NOT.fs(2)%lShpF) THEN
                  CALL GNN(fs(2)%eNoN, nsd, fs(2)%Nx(:,:,g), xql, Nqx,
     2                Jac, ksix)
                  IF (ISZERO(Jac)) err = "Jac < 0 @ element "//e
               END IF

               IF (g.EQ.1 .OR. .NOT.fs(1)%lShpF) THEN
                  CALL GNN(fs(1)%eNoN, nsd, fs(1)%Nx(:,:,g), xwl, Nwx, 
     2               Jac, ksix)
                  IF (ISZERO(Jac)) err = "Jac < 0 @ element "//e

                  CALL GNNxx(l, fs(1)%eNoN, nsd, fs(1)%Nx(:,:,g),
     2               fs(1)%Nxx(:,:,g), xwl, Nwx, Nwxx)
               END IF
               w = fs(1)%w(g) * Jac

               IF (nsd .EQ. 3) THEN
                  SELECT CASE (cPhys)
                  CASE (phys_fluid)
                     CALL FLUID3D_M(vmsStab, fs(1)%eNoN, fs(2)%eNoN, w,
     2                  ksix, fs(1)%N(:,g), fs(2)%N(:,g), Nwx, Nqx, 
     3                  Nwxx, al, yl, bfl, lR, lK)

                  CASE (phys_lElas)
                     CALL LELAS3D(fs(1)%eNoN, w, fs(1)%N(:,g), Nwx, al, 
     2                  dl, bfl, pS0l, pSl, lR, lK)

                  CASE (phys_struct)
                     CALL STRUCT3D(fs(1)%eNoN, nFn, w, fs(1)%N(:,g), 
     2                  Nwx, al, yl, dl, bfl, fN, pS0l, pSl, tmXl, ya_l,
     3                  lR, lK)

                  CASE (phys_ustruct)
                     CALL USTRUCT3D_M(vmsStab, fs(1)%eNoN, fs(2)%eNoN, 
     2                  nFn, w, Jac, fs(1)%N(:,g), fs(2)%N(:,g), Nwx,  
     3                  al, yl, dl, bfl, fN, tmXl, ya_l, lR, lK, lKd)

                  END SELECT

               ELSE IF (nsd .EQ. 2) THEN
                  SELECT CASE (cPhys)
                  CASE (phys_fluid)
                     CALL FLUID2D_M(vmsStab, fs(1)%eNoN, fs(2)%eNoN, w,
     2                  ksix, fs(1)%N(:,g), fs(2)%N(:,g), Nwx, Nqx, 
     3                  Nwxx, al, yl, bfl, lR, lK)

                  CASE (phys_lElas)
                     CALL LELAS2D(fs(1)%eNoN, w, fs(1)%N(:,g), Nwx, al, 
     2                  dl, bfl, pS0l, pSl, lR, lK)

                  CASE (phys_struct)
                     CALL STRUCT2D(fs(1)%eNoN, nFn, w, fs(1)%N(:,g), 
     2                  Nwx, al, yl, dl, bfl, fN, pS0l, pSl, tmXl, ya_l,  
     3                  lR, lK)

                  CASE (phys_ustruct)
                     CALL USTRUCT2D_M(vmsStab, fs(1)%eNoN, fs(2)%eNoN, 
     2                  nFn, w, Jac, fs(1)%N(:,g), fs(2)%N(:,g), Nwx,  
     3                  al, yl, dl, bfl, fN, tmXl, ya_l, lR, lK, lKd)

                  END SELECT
               END IF
            END DO ! g: loop
         END IF

!        Set function spaces for velocity and pressure.
         CALL GETTHOODFS(fs, lM, vmsStab, 2)

!        Gauss integration 2
         DO g=1, fs(2)%nG
            IF (g.EQ.1 .OR. .NOT.fs(1)%lShpF) THEN
               CALL GNN(fs(1)%eNoN, nsd, fs(1)%Nx(:,:,g), xwl, Nwx, Jac,
     2            ksix)
               IF (ISZERO(Jac)) err = "Jac < 0 @ element "//e
            END IF

            IF (g.EQ.1 .OR. .NOT.fs(2)%lShpF) THEN
               CALL GNN(fs(2)%eNoN, nsd, fs(2)%Nx(:,:,g), xql, Nqx, Jac,
     2            ksix)
               IF (ISZERO(Jac)) err = "Jac < 0 @ element "//e
            END IF
            w = fs(2)%w(g) * Jac

            IF (nsd .EQ. 3) THEN
               SELECT CASE (cPhys)
               CASE (phys_fluid)
                  CALL FLUID3D_C(vmsStab, fs(1)%eNoN, fs(2)%eNoN, w,
     2               ksix, fs(1)%N(:,g), fs(2)%N(:,g), Nwx, Nqx, Nwxx,
     3               al, yl, bfl, lR, lK)

               CASE (phys_ustruct)
                  CALL USTRUCT3D_C(vmsStab, fs(1)%eNoN, fs(2)%eNoN, w,
     2               Jac, fs(1)%N(:,g), fs(2)%N(:,g), Nwx, Nqx, al, yl,
     3               dl, bfl, lR, lK, lKd)
               END SELECT

            ELSE IF (nsd .EQ. 2) THEN
               SELECT CASE (cPhys)
               CASE (phys_fluid)
                  CALL FLUID2D_C(vmsStab, fs(1)%eNoN, fs(2)%eNoN, w,
     2               ksix, fs(1)%N(:,g), fs(2)%N(:,g), Nwx, Nqx, Nwxx,
     3               al, yl, bfl, lR, lK)

               CASE (phys_ustruct)
                  CALL USTRUCT2D_C(vmsStab, fs(1)%eNoN, fs(2)%eNoN, w,
     2               Jac, fs(1)%N(:,g), fs(2)%N(:,g), Nwx, Nqx, al, yl,
     3               dl, bfl, lR, lK, lKd)
               END SELECT
            END IF
         END DO ! g: loop

         DEALLOCATE(xwl, xql, Nwx, Nwxx, Nqx)

!        Assembly
#ifdef WITH_TRILINOS
         IF (eq(cEq)%assmTLS) THEN
            IF (cPhys .EQ. phys_ustruct) err = "Cannot assemble "//
     2         "USTRUCT using Trilinos"
            IF (.NOT.(lM%lShl .AND. lM%eType.EQ.eType_TRI3)) THEN
               CALL TRILINOS_DOASSEM(eNoN, ptr, lK, lR)
            END IF
         ELSE
#endif
            IF (cPhys .EQ. phys_ustruct) THEN
               CALL USTRUCT_DOASSEM(eNoN, ptr, lKd, lK, lR)
            ELSEIF (.NOT.(lM%lShl .AND. lM%eType.EQ.eType_TRI3)) THEN
               CALL DOASSEM(eNoN, ptr, lK, lR)
            END IF
#ifdef WITH_TRILINOS
         END IF
#endif
      END DO ! e: loop

      DEALLOCATE(ptr, xl, al, yl, dl, bfl, fN, pS0l, pSl, tmXl, ya_l,
     2    lR, lK, lKd)

      CALL DESTROY(fs(1))
      CALL DESTROY(fs(2))

      RETURN
      END SUBROUTINE CONSTRUCT_FSI
!####################################################################
